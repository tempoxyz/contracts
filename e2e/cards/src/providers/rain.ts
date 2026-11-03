// Rain as a card provider: Rain's own collateral contracts (cards/vendor/rain, deployed from
// cards/test/rain/fixtures/rain.json), a RainCardProgram adapter, and Rain's back office after a spend lands:
// a cardholder-signed refund withdrawal and the daily payment to Rain's treasury, both authorized by
// Rain's controller admin's EIP-712 signature, as on Rain's live contracts.
import { execFileSync } from 'node:child_process'
import { mkdirSync, readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import {
  concat,
  encodeAbiParameters,
  encodePacked,
  erc20Abi,
  formatUnits,
  keccak256,
  parseAbi,
  toFunctionSelector,
  toHex,
  zeroAddress,
  zeroHash,
  type Address,
  type Hex,
} from 'viem'
import { generatePrivateKey, privateKeyToAccount, type PrivateKeyAccount } from 'viem/accounts'

import { forgeEnv } from '../../bridge/src/targets.js'
import { assert, revertData } from '../../bridge/src/support.js'
import type { CardProvider, Context, Deployed } from '../provider.js'

export const cardsRoot = resolve(new URL('.', import.meta.url).pathname, '../../../../cards')

const programAbi = parseAbi([
  'function setPaused(bool paused)',
  'function paused() view returns (bool)',
])
const spenderAbi = parseAbi([
  'struct CardSpend { address program; address token; uint256 amount; address destination; uint256 destinationHint; address vault; uint256 fromVault; uint256 maxShares; bytes32 ref; }',
  'function spend(CardSpend s)',
  'error ProgramPaused()',
])
const controllerAbi = parseAbi([
  'function nonce(address collateral) view returns (uint256)',
  'function treasury() view returns (address)',
  'function controllerAdmin() view returns (address)',
  'function EIP712_DOMAIN_TYPE_HASH() view returns (bytes32)',
  'function PAY_TYPE_HASH() view returns (bytes32)',
  'function WITHDRAW_TYPE_HASH() view returns (bytes32)',
  'function makePayment(address collateral, address[] assets, uint256[] amounts, uint256 expiresAt, bytes32 salt, bytes signature)',
  'function withdrawAsset(address collateral, address asset, uint256 amount, address recipient, uint256 expiresAt, bytes32 salt, bytes signature)',
])
const collateralAbi = parseAbi([
  'function withdrawAsset(address asset, address recipient, uint256 amount)',
  'function isAdmin(address account) view returns (bool)',
])

type RainDeployment = {
  rainFactory: Address
  rainController: Address
  cardholderCollateral: Address
  cardholderCollateralIndex: number
  programCollateral: Address
  programCollateralIndex: number
  program: Address
  spender: Address
  settler: Address
  routerFactory: Address
  router: Address
  zoneToken: Address
  earnVault?: Address
  earnShare?: Address
}

export function rain(): CardProvider {
  const adminPk = generatePrivateKey()
  const admin = privateKeyToAccount(adminPk)
  const backend = privateKeyToAccount(generatePrivateKey())
  const treasury = privateKeyToAccount(generatePrivateKey()).address
  const partner = privateKeyToAccount(generatePrivateKey()).address
  let deployment: RainDeployment | undefined

  return {
    name: 'rain',
    accounts: [backend],
    deploy(input) {
      mkdirSync(resolve(cardsRoot, 'reports'), { recursive: true })
      const out = `reports/cards-e2e-rain-${input.zoneId}.json`
      try {
        execFileSync(
          'forge',
          [
            'script',
            'script/rain/CardsE2EDeploy.s.sol',
            '--rpc-url',
            input.rpcUrl,
            '--broadcast',
            '--slow',
            '--gas-estimate-multiplier',
            '105',
          ],
          {
            cwd: cardsRoot,
            stdio: ['ignore', 'pipe', 'pipe'],
            encoding: 'utf8',
            env: forgeEnv({
              DEPLOYER_PK: input.deployerPk,
              RAIN_ADMIN: admin.address,
              RAIN_TREASURY: treasury,
              RAIN_PAUSER: backend.address,
              CARDHOLDER: input.cardholder,
              PARTNER: partner,
              ZONE_ID: String(input.zoneId),
              EARN: String(input.earn),
              OUT: out,
            }),
          },
        )
      } catch (error) {
        const failed = error as { stdout?: string; stderr?: string }
        throw new Error(`CardsE2EDeploy failed:
${failed.stdout ?? ''}${failed.stderr ?? ''}`)
      }
      const d = JSON.parse(readFileSync(resolve(cardsRoot, out), 'utf8')) as RainDeployment
      deployment = d
      const deployed: Deployed = {
        program: d.program,
        spender: d.spender,
        settler: d.settler,
        router: d.router,
        routerFactory: d.routerFactory,
        zoneToken: d.zoneToken,
        publicDestination: {
          address: d.cardholderCollateral,
          hint: BigInt(d.cardholderCollateralIndex),
          label: "the cardholder's Rain collateral",
        },
        privateDestination: {
          address: d.programCollateral,
          hint: BigInt(d.programCollateralIndex),
          label: "the program's pooled Rain collateral",
        },
        // The cardholder's own collateral names them, and the settler (the payer) does not own it.
        refusedPrivateDestination: {
          address: d.cardholderCollateral,
          hint: BigInt(d.cardholderCollateralIndex),
          label: "the cardholder's own Rain collateral",
        },
        ...(d.earnVault && d.earnShare
          ? { earn: { vault: d.earnVault, earnShare: d.earnShare } }
          : {}),
      }
      return deployed
    },
    async settle(ctx, deployed, firstStep) {
      const d = deployment!
      let n = firstStep
      const { l1Public, token, cardholder } = ctx
      const balanceOf = (account: Address) =>
        l1Public.readContract({
          address: token,
          abi: erc20Abi,
          functionName: 'balanceOf',
          args: [account],
        })
      const onChainAdmin = await l1Public.readContract({
        address: d.rainController,
        abi: controllerAbi,
        functionName: 'controllerAdmin',
      })
      assert(onChainAdmin === admin.address, "Rain's controller admin is the run's signing key")

      // Rain's controller is the only caller its collateral contracts answer.
      const direct = await l1Public
        .simulateContract({
          account: cardholder,
          address: d.cardholderCollateral,
          abi: collateralAbi,
          functionName: 'withdrawAsset',
          args: [token, cardholder.address, 1n],
        })
        .then(
          () => 'succeeded',
          () => 'reverted',
        )
      assert(direct === 'reverted', 'a direct withdrawal from the collateral contract reverts')

      // Rain's pause key stops every spend of the program, and only Rain's key resumes them.
      const setPaused = async (paused: boolean) => {
        const receipt = await ctx.l1Wallet(backend).writeContractSync({
          address: d.program,
          abi: programAbi,
          functionName: 'setPaused',
          args: [paused],
          feeToken: token,
        } as never)
        assert(receipt.status === 'success', 'Rain set the pause')
      }
      const probe = () =>
        l1Public
          .simulateContract({
            account: cardholder,
            address: deployed.spender,
            abi: spenderAbi,
            functionName: 'spend',
            args: [
              {
                program: d.program,
                token,
                amount: 1n,
                destination: deployed.publicDestination.address,
                destinationHint: deployed.publicDestination.hint,
                vault: zeroAddress,
                fromVault: 0n,
                maxShares: 0n,
                ref: zeroHash,
              },
            ],
          })
          .then(
            () => 'allowed',
            (error: unknown) =>
              revertData(error) === toFunctionSelector('ProgramPaused()') ? 'paused' : 'refused',
          )
      await setPaused(true)
      assert(
        await l1Public.readContract({
          address: d.program,
          abi: programAbi,
          functionName: 'paused',
        }),
        'the program is paused',
      )
      assert((await probe()) === 'paused', 'a spend reverts with ProgramPaused while paused')
      const strangerPause = await l1Public
        .simulateContract({
          account: cardholder,
          address: d.program,
          abi: programAbi,
          functionName: 'setPaused',
          args: [false],
        })
        .then(
          () => 'allowed',
          () => 'refused',
        )
      assert(strangerPause === 'refused', "only Rain's pause key can resume spends")
      await setPaused(false)
      assert(
        !(await l1Public.readContract({
          address: d.program,
          abi: programAbi,
          functionName: 'paused',
        })),
        'the program resumed',
      )
      ctx.step(
        n++,
        "Rain's pause key stopped every spend (ProgramPaused) and resumed them; nobody else can",
      )

      // A reversal: the cardholder, admin of their own collateral, withdraws with Rain's signature.
      const refund = 1_000_000n
      const publicFunded = ctx.funded.get(d.cardholderCollateral) ?? 0n
      assert(publicFunded > refund, 'the public spends funded the cardholder collateral')
      // Paid to a fresh account of the cardholder's, since the cardholder pays the transaction's fee in pathUSD.
      const refundTo = privateKeyToAccount(generatePrivateKey()).address
      const collateralBefore = await balanceOf(d.cardholderCollateral)
      await send(ctx, cardholder, d.rainController, 'withdrawAsset', async (expiresAt, salt) => [
        d.cardholderCollateral,
        token,
        refund,
        refundTo,
        expiresAt,
        salt,
        await sign(ctx, d, admin, 'withdraw', {
          caller: cardholder.address,
          collateral: d.cardholderCollateral,
          asset: token,
          amount: refund,
          recipient: refundTo,
          expiresAt,
          salt,
        }),
      ])
      assert(
        (await balanceOf(refundTo)) === refund &&
          collateralBefore - (await balanceOf(d.cardholderCollateral)) === refund,
        'the Rain-signed withdrawal moved exactly the refund out of the collateral to the cardholder',
      )
      ctx.step(
        n++,
        `Rain refund: the cardholder withdrew ${formatUnits(refund, 6)} pathUSD from their collateral with Rain's EIP-712 signature (a direct withdrawal reverts)`,
      )

      // Rain's daily payment: what is left in each collateral moves to Rain's treasury.
      for (const [collateral, label] of [
        [d.cardholderCollateral, 'cardholder'],
        [d.programCollateral, 'pooled program'],
      ] as const) {
        const held = await balanceOf(collateral)
        const expected =
          (ctx.funded.get(collateral) ?? 0n) - (collateral === d.cardholderCollateral ? refund : 0n)
        assert(
          held === expected,
          `the ${label} collateral holds exactly what the spends funded (${held})`,
        )
        const treasuryBefore = await balanceOf(treasury)
        await send(ctx, backend, d.rainController, 'makePayment', async (expiresAt, salt) => [
          collateral,
          [token],
          [held],
          expiresAt,
          salt,
          await sign(ctx, d, admin, 'pay', {
            caller: backend.address,
            collateral,
            asset: token,
            amount: held,
            expiresAt,
            salt,
          }),
        ])
        assert(
          (await balanceOf(treasury)) - treasuryBefore === held,
          "Rain's treasury received the payment",
        )
        assert((await balanceOf(collateral)) === 0n, `the ${label} collateral is settled`)
        ctx.step(
          n++,
          `Rain's daily payment: ${formatUnits(held, 6)} pathUSD from the ${label} collateral to Rain's treasury, signed by Rain's controller admin`,
        )
      }
      return n
    },
  }
}

async function send(
  ctx: Context,
  account: PrivateKeyAccount,
  controller: Address,
  functionName: 'makePayment' | 'withdrawAsset',
  args: (expiresAt: bigint, salt: Hex) => Promise<readonly unknown[]>,
) {
  const block = await ctx.l1Public.getBlock()
  const expiresAt = block.timestamp + 1800n
  const salt = keccak256(toHex(`rain.${functionName}.${Date.now()}.${Math.random()}`))
  const receipt = await ctx.l1Wallet(account).writeContractSync({
    address: controller,
    abi: controllerAbi,
    functionName,
    args: (await args(expiresAt, salt)) as never,
    feeToken: ctx.token,
  } as never)
  assert(receipt.status === 'success', `Rain ${functionName} succeeded`)
}

/** Rain's controller admin's EIP-712 signature over a Pay or Withdraw, as RainCollateralController hashes it. */
async function sign(
  ctx: Context,
  d: RainDeployment,
  admin: PrivateKeyAccount,
  kind: 'pay' | 'withdraw',
  m: {
    caller: Address
    collateral: Address
    asset: Address
    amount: bigint
    recipient?: Address
    expiresAt: bigint
    salt: Hex
  },
) {
  const read = (
    functionName: 'EIP712_DOMAIN_TYPE_HASH' | 'PAY_TYPE_HASH' | 'WITHDRAW_TYPE_HASH' | 'nonce',
  ) =>
    ctx.l1Public.readContract({
      address: d.rainController,
      abi: controllerAbi,
      functionName,
      ...(functionName === 'nonce' ? { args: [m.collateral] } : {}),
    } as never) as Promise<Hex | bigint>
  const [domainType, typeHash, nonce] = await Promise.all([
    read('EIP712_DOMAIN_TYPE_HASH') as Promise<Hex>,
    read(kind === 'pay' ? 'PAY_TYPE_HASH' : 'WITHDRAW_TYPE_HASH') as Promise<Hex>,
    read('nonce') as Promise<bigint>,
  ])
  const chainId = BigInt(await ctx.l1Public.getChainId())
  const domain = keccak256(
    encodeAbiParameters(
      [
        { type: 'bytes32' },
        { type: 'bytes32' },
        { type: 'bytes32' },
        { type: 'uint256' },
        { type: 'address' },
        { type: 'bytes32' },
      ],
      [
        domainType,
        keccak256(toHex('Rain Collateral')),
        keccak256(toHex('1')),
        chainId,
        d.rainController,
        m.salt,
      ],
    ),
  )
  const structHash =
    kind === 'pay'
      ? keccak256(
          concat([
            encodeAbiParameters(
              [
                { type: 'bytes32' },
                { type: 'address' },
                { type: 'address' },
                { type: 'bytes32' },
                { type: 'bytes32' },
              ],
              [
                typeHash,
                m.caller,
                m.collateral,
                keccak256(encodePacked(['address[]'], [[m.asset]])),
                keccak256(encodePacked(['uint256[]'], [[m.amount]])),
              ],
            ),
            encodeAbiParameters([{ type: 'uint256' }, { type: 'uint256' }], [nonce, m.expiresAt]),
          ]),
        )
      : keccak256(
          concat([
            encodeAbiParameters(
              [
                { type: 'bytes32' },
                { type: 'address' },
                { type: 'address' },
                { type: 'address' },
                { type: 'uint256' },
              ],
              [typeHash, m.caller, m.collateral, m.asset, m.amount],
            ),
            encodeAbiParameters(
              [{ type: 'address' }, { type: 'uint256' }, { type: 'uint256' }],
              [m.recipient!, nonce, m.expiresAt],
            ),
          ]),
        )
  return admin.sign({ hash: keccak256(concat(['0x1901', domain, structHash])) })
}
