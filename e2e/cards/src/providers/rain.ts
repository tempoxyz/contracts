// Rain as a card provider: Rain's own collateral contracts (cards/vendor/rain, deployed from
// cards/test/rain/fixtures/rain.json), a RainProvider on a CardSpender, and Rain's back office after a spend lands:
// a cardholder-signed refund withdrawal and the daily payment to Rain's treasury, both authorized by
// Rain's controller admin's EIP-712 signature, as on Rain's live contracts.
import { execFileSync } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { mkdirSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { resolve } from 'node:path'
import {
  concat,
  encodeAbiParameters,
  encodeErrorResult,
  encodePacked,
  erc20Abi,
  formatUnits,
  isAddress,
  isAddressEqual,
  keccak256,
  parseAbi,
  toHex,
  zeroAddress,
  type Address,
  type Hex,
} from 'viem'
import { generatePrivateKey, privateKeyToAccount, type PrivateKeyAccount } from 'viem/accounts'

import { forgeEnv } from '../../bridge/src/targets.js'
import { assert, revertData } from '../../bridge/src/support.js'
import type { CardProvider, Context, Deployed } from '../provider.js'

export const cardsRoot = resolve(new URL('.', import.meta.url).pathname, '../../../../cards')

const programAbi = parseAbi(['function paused() view returns (bool)'])
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

type RainIdentity = {
  runId: string
  chainId: number
  zoneId: number
  deployer: Address
  rainAdmin: Address
  rainTreasury: Address
  cardholder: Address
  partner: Address
  earn: boolean
}

type RainDeployment = RainIdentity & {
  rainFactory: Address
  rainController: Address
  cardholderCollateral: Address
  cardholderCollateralIndex: number
  programCollateral: Address
  programCollateralIndex: number
  cardFactory: Address
  provider: Address
  program: Address
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
      const d = withRainReport((out, runId) => {
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
                RAIN_RUN_ID: runId,
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
        return parseRainDeployment(readFileSync(out, 'utf8'), {
          runId,
          chainId: input.chainId,
          zoneId: input.zoneId,
          deployer: privateKeyToAccount(input.deployerPk).address,
          rainAdmin: admin.address,
          rainTreasury: treasury,
          cardholder: input.cardholder,
          partner,
          earn: input.earn,
        })
      })
      deployment = d
      const deployed: Deployed = {
        program: d.program,
        provider: d.provider,
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
        // The cardholder's own collateral names them, so a private spend may not fund it.
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

      // A funded, otherwise valid withdrawal must fail at Rain's controller-only gate, not at RPC or token handling.
      assert(
        (await balanceOf(d.cardholderCollateral)) > 0n,
        'the collateral is funded before the authorization probe',
      )
      await expectUnauthorizedWithdrawal(
        l1Public.simulateContract({
          account: cardholder,
          address: d.cardholderCollateral,
          abi: collateralAbi,
          functionName: 'withdrawAsset',
          args: [token, cardholder.address, 1n],
        }),
      )

      // Rain's contracts have no pause, so neither has the program: Rain stops a program by not sending
      // spends, since only its keys send them and they can pay only collateral Rain controls.
      assert(
        !(await l1Public.readContract({
          address: d.program,
          abi: programAbi,
          functionName: 'paused',
        })),
        'the program reports no pause',
      )
      ctx.step(n++, 'The program reports no pause: Rain stops a program by not sending spends')

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

/** Requires Rain's exact controller-only rejection; transport failures and other reverts are not authorization evidence. */
export async function expectUnauthorizedWithdrawal(simulation: Promise<unknown>) {
  const data = await simulation.then(() => undefined, revertData)
  const unauthorized = encodeErrorResult({
    abi: parseAbi(['error Error(string)']),
    errorName: 'Error',
    args: ['Unauthorized'],
  })
  assert(
    data?.toLowerCase() === unauthorized,
    'a direct collateral withdrawal reverts with exactly Unauthorized',
  )
}

/** Keeps each Forge report private to its invocation, including two runs for the same Zone. */
export function withRainReport<result>(consume: (out: string, runId: string) => result): result {
  mkdirSync(resolve(cardsRoot, 'reports'), { recursive: true })
  const directory = mkdtempSync(resolve(cardsRoot, 'reports/cards-e2e-rain-'))
  try {
    return consume(resolve(directory, 'deployment.json'), randomUUID())
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
}

/** Rejects foreign, stale or incomplete deployment reports before any address is adopted by the run. */
export function parseRainDeployment(json: string, expected: RainIdentity): RainDeployment {
  const d = JSON.parse(json) as RainDeployment
  assert(d !== null && typeof d === 'object' && !Array.isArray(d), 'Rain report is an object')
  for (const field of ['runId', 'chainId', 'zoneId', 'earn'] as const)
    assert(d[field] === expected[field], `Rain report ${field} matches this run`)
  for (const field of ['deployer', 'rainAdmin', 'rainTreasury', 'cardholder', 'partner'] as const) {
    assert(
      typeof d[field] === 'string' && isAddress(d[field]),
      `Rain report ${field} is an address`,
    )
    assert(isAddressEqual(d[field], expected[field]), `Rain report ${field} matches this run`)
  }
  for (const field of [
    'rainFactory',
    'rainController',
    'cardholderCollateral',
    'programCollateral',
    'cardFactory',
    'provider',
    'program',
    'routerFactory',
    'router',
    'zoneToken',
    ...(expected.earn ? (['earnVault', 'earnShare'] as const) : []),
  ] as const) {
    const address = d[field]
    assert(
      typeof address === 'string' && isAddress(address) && !isAddressEqual(address, zeroAddress),
      `Rain report ${field} is a nonzero address`,
    )
  }
  assert(
    d.cardholderCollateralIndex === 0 && d.programCollateralIndex === 1,
    'Rain report uses the deployed collateral indexes',
  )
  if (!expected.earn)
    assert(
      d.earnVault === undefined && d.earnShare === undefined,
      'Rain report has no unrequested Earn deployment',
    )
  return d
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
