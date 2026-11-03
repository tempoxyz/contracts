// Card spend end to end on a disposable Tempo L1 and Zone, for any card provider (provider.ts):
//
//   pnpm e2e:cards                         Rain, stablecoin spends
//   pnpm e2e:cards -- --earn               Rain, plus spends from Tempo Earn shares, public and private
//   pnpm e2e:cards -- --provider rain      the provider to run (rain is the only one so far)
//
// 1. Starts the L1, has the provider deploy its own contracts and a card program on the
//    provider-agnostic CardSpender and CardSettler with a Spend-mode ZoneRouter listing the settler,
//    then starts the Zone and registers the router as its gateway.
// 2. Public: the cardholder authorizes the provider's access key, scoped to approving the spender and
//    calling `spend`; the provider sends single L1 transactions (approve exact, spend, clear) that pay
//    the provider's public destination. With --earn, one more spend redeems Earn shares for it.
// 3. Private: the cardholder deposits into the Zone and authorizes the provider's Zone key, scoped to the
//    outbox; the provider requests withdrawals to the router whose callback pays the provider's private
//    destination through the settler. Checks: the destination is paid exactly, no L1 log of the
//    settlement names the cardholder, the Zone balance ends exactly the spend and fees lower, and a spend
//    to a destination the program refuses for private spend bounces back into the Zone in full. With
//    --earn, a private spend from Earn shares returns the unused shares to the Zone.
// 4. Hands the funded destinations to the provider's own back office (Rain: a signed refund and the daily
//    payment to its treasury) and writes the timings to cards/reports/cards-e2e-<provider>.json.
import { execFileSync } from 'node:child_process'
import { writeFileSync } from 'node:fs'
import { resolve } from 'node:path'
import {
  encodeAbiParameters,
  encodeFunctionData,
  erc20Abi,
  formatUnits,
  isAddressEqual,
  keccak256,
  parseAbi,
  parseAbiParameters,
  parseEventLogs,
  toFunctionSelector,
  toHex,
  zeroAddress,
  zeroHash,
  type Address,
  type Hex,
} from 'viem'
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts'
import { Account, Actions } from 'viem/tempo'

import * as Network from '../bridge/src/network.js'
import {
  CALLBACK_GAS,
  OP_SPEND,
  assert,
  median,
  names,
  outbox,
  outboxAbi,
  pathUsd,
  portalEventsAbi,
  revertData,
  since,
  spendDataType,
  step,
  waitFor,
  withdrawalRequested,
  zoneTokenAbi,
} from '../bridge/src/support.js'
import { forgeEnv, portalAbi, sendL1Sync } from '../bridge/src/targets.js'
import { l1Clients, zoneClients, type ZoneClient } from './clients.js'
import type { CardProvider, Context, Deployed, Destination } from './provider.js'
import { cardsRoot, rain } from './providers/rain.js'

const providers: Record<string, () => CardProvider> = { rain }

const DEPOSIT = 100_000_000n // 100 pathUSD
const SPEND = 20_000_000n // 20 pathUSD
const PUBLIC_SPENDS = 3
const SHARE_TOLERANCE_BPS = 50n

export const cardSpendType = parseAbiParameters([
  'CardSpend spend',
  'struct CardSpend { address program; address token; uint256 amount; address destination; uint256 destinationHint; address vault; uint256 fromVault; uint256 maxShares; bytes32 ref; }',
])
const spenderAbi = parseAbi([
  'struct CardSpend { address program; address token; uint256 amount; address destination; uint256 destinationHint; address vault; uint256 fromVault; uint256 maxShares; bytes32 ref; }',
  'function spend(CardSpend s)',
  'event CardSpent(bytes32 indexed ref, address indexed payer, address indexed destination, address token, uint256 amount, uint256 fromStable, uint256 fromVault, uint256 sharesBurned)',
])
const settlerAbi = parseAbi([
  'event SpendSettled(bytes32 indexed ref, address inputToken, uint256 inputConsumed, uint256 inputReturned)',
])
const routerAbi = parseAbi([
  'event Spent(address indexed settler, address indexed token, uint256 used, uint256 change, bytes32 zoneDepositHash)',
])
const earnVaultAbi = parseAbi([
  'function deposit(uint256 assets, address receiver, uint256 minEarnShares) returns (uint256)',
  'function previewWithdraw(uint256 assets) view returns (uint256)',
])
const SPEND_SELECTOR =
  'spend((address,address,uint256,address,uint256,address,uint256,uint256,bytes32))'

type CardSpendArgs = {
  program: Address
  token: Address
  amount: bigint
  destination: Address
  destinationHint: bigint
  vault: Address
  fromVault: bigint
  maxShares: bigint
  ref: Hex
}

function cardSpend(
  d: Deployed,
  to: Destination,
  amount: bigint,
  ref: Hex,
  earn?: { maxShares: bigint },
): CardSpendArgs {
  return {
    program: d.program,
    token: pathUsd,
    amount,
    destination: to.address,
    destinationHint: to.hint,
    vault: earn ? d.earn!.vault : zeroAddress,
    fromVault: earn ? amount : 0n,
    maxShares: earn?.maxShares ?? 0n,
    ref,
  }
}

async function main() {
  const args = process.argv.slice(2)
  const name = args.includes('--provider') ? args[args.indexOf('--provider') + 1]! : 'rain'
  const make = providers[name]
  if (!make) throw new Error(`unknown provider ${name}: use ${Object.keys(providers).join(', ')}`)
  const provider = make()
  const withEarn = args.includes('--earn')
  execFileSync('forge', ['build'], { cwd: cardsRoot, stdio: 'ignore', env: forgeEnv() })

  const zoneAdminPk = generatePrivateKey()
  const zoneAdmin = privateKeyToAccount(zoneAdminPk)
  const deployerPk = generatePrivateKey()
  const cardholder = privateKeyToAccount(generatePrivateKey())
  const refundRecipient = privateKeyToAccount(generatePrivateKey()).address
  const run = `${name}.${Date.now()}`
  const ref = (label: string) => keccak256(toHex(`cards-e2e.${run}.${label}`))

  const l1 = await Network.startL1(zoneAdmin.address)
  let zone: Network.Zone | undefined
  try {
    step(1, `Tempo L1 at ${l1.rpcUrl} (chain ${l1.chainId}), provider ${provider.name}`)
    const { l1Public, l1Wallet } = l1Clients(l1)
    for (const a of [
      zoneAdmin,
      privateKeyToAccount(deployerPk),
      cardholder,
      ...provider.accounts,
    ]) {
      await l1Public.faucet.fundSync({ account: a.address, timeout: 180_000 })
    }
    const deployed = provider.deploy({
      rpcUrl: l1.rpcUrl,
      deployerPk,
      cardholder: cardholder.address,
      zoneId: 1,
      earn: withEarn,
    })
    step(
      2,
      `${provider.name} program ${deployed.program} on CardSpender ${deployed.spender}, CardSettler ${deployed.settler} and Spend ZoneRouter ${deployed.router}`,
    )
    zone = await Network.startZone({
      l1,
      initialToken: deployed.zoneToken,
      privateKey: zoneAdminPk,
    })
    const portal = zone.portal
    const admin = l1Wallet(zoneAdmin)
    const portalCall = (
      functionName: 'enableToken' | 'setGateway' | 'setAllowedAccount',
      a: readonly unknown[],
    ) =>
      admin.writeContractSync({
        address: portal,
        abi: portalAbi,
        functionName,
        args: a,
        feeToken: pathUsd,
      } as never)
    const portalRead = <T>(functionName: string, a: readonly unknown[] = []) =>
      l1Public.readContract({
        address: portal,
        abi: portalAbi,
        functionName,
        args: a,
      } as never) as Promise<T>
    for (const token of [pathUsd, ...(deployed.earn ? [deployed.earn.earnShare] : [])]) {
      if (!(await portalRead<boolean>('isTokenEnabled', [token])))
        await portalCall('enableToken', [token])
    }
    const gatewayOpen = await portalRead<boolean>('isGatewayOpen')
    if (!gatewayOpen) await portalCall('setGateway', [deployed.router, true])
    if (await portalRead<boolean>('isAccessEnforced'))
      for (const a of [
        cardholder.address,
        refundRecipient,
        ...(gatewayOpen ? [deployed.router] : []),
      ])
        await portalCall('setAllowedAccount', [a, true])
    step(
      3,
      `Tempo Zone ${zone.zoneId} at ${zone.publicRpcUrl}, portal ${portal}, router registered`,
    )

    const funded = new Map<Address, bigint>()
    const fund = (to: Address, amount: bigint) => funded.set(to, (funded.get(to) ?? 0n) + amount)
    const ctx: Context = { l1Public, l1Wallet, step, cardholder, token: pathUsd, funded }
    const balanceOf = (token: Address, account: Address) =>
      l1Public.readContract({
        address: token,
        abi: erc20Abi,
        functionName: 'balanceOf',
        args: [account],
      })

    // ---------------------------------------------------------------------------------------------
    // Public spend: one L1 transaction from the cardholder's account, signed by the provider's key
    // ---------------------------------------------------------------------------------------------
    const userL1 = l1Wallet(cardholder)
    const write = async (request: object) => {
      const receipt = await userL1.writeContractSync({ ...request, feeToken: pathUsd } as never)
      assert(receipt.status === 'success', 'cardholder L1 transaction succeeded')
    }
    let earnShares = 0n
    if (deployed.earn) {
      await write({
        address: pathUsd,
        abi: erc20Abi,
        functionName: 'approve',
        args: [deployed.earn.vault, 4n * SPEND],
      })
      await write({
        address: deployed.earn.vault,
        abi: earnVaultAbi,
        functionName: 'deposit',
        args: [4n * SPEND, cardholder.address, 1n],
      })
      earnShares = await balanceOf(deployed.earn.earnShare, cardholder.address)
      assert(earnShares > 0n, 'the cardholder holds EarnShare')
    }
    const keyPk = generatePrivateKey()
    const key = privateKeyToAccount(keyPk).address
    const limit = BigInt(PUBLIC_SPENDS + 2) * SPEND
    const scopes = [
      { address: pathUsd, selector: 'approve(address,uint256)', recipients: [deployed.spender] },
      { address: deployed.spender, selector: SPEND_SELECTOR },
      ...(deployed.earn
        ? [
            {
              address: deployed.earn.earnShare,
              selector: 'approve(address,uint256)',
              recipients: [deployed.spender],
            },
          ]
        : []),
    ]
    await userL1.accessKey.authorizeSync({
      accessKey: { accessKeyAddress: key, keyType: 'secp256k1' },
      expiry: Math.floor(Date.now() / 1000) + 86_400,
      limits: [
        { token: pathUsd, limit, period: 30 * 86_400 },
        ...(deployed.earn
          ? [{ token: deployed.earn.earnShare, limit: earnShares, period: 30 * 86_400 }]
          : []),
      ],
      scopes,
      feeToken: pathUsd,
    } as never)
    step(
      4,
      `Cardholder authorized ${provider.name}'s L1 access key: approve the CardSpender and call spend, nothing else`,
    )
    const providerL1 = l1Wallet(
      Account.fromSecp256k1(keyPk, { access: cardholder.address }) as never,
    )
    const approve = (token: Address, amount: bigint) => ({
      to: token,
      data: encodeFunctionData({
        abi: erc20Abi,
        functionName: 'approve',
        args: [deployed.spender, amount],
      }),
    })
    const spendCall = (s: CardSpendArgs) => ({
      to: deployed.spender,
      data: encodeFunctionData({ abi: spenderAbi, functionName: 'spend', args: [s] }),
    })
    const publicMs: number[] = []
    const destination = deployed.publicDestination
    for (let i = 0; i < PUBLIC_SPENDS; i++) {
      const before = await balanceOf(pathUsd, destination.address)
      const sent = await sendL1Sync(providerL1 as never, l1Public, [
        approve(pathUsd, SPEND),
        spendCall(cardSpend(deployed, destination, SPEND, ref(`public.${i}`))),
        approve(pathUsd, 0n),
      ])
      publicMs.push(sent.ms)
      assert(sent.receipt.status === 'success', 'public spend settled in one L1 transaction')
      assert(
        (await balanceOf(pathUsd, destination.address)) - before === SPEND,
        `${destination.label} received exactly the spend`,
      )
      fund(destination.address, SPEND)
    }
    assert(
      (await l1Public.readContract({
        address: pathUsd,
        abi: erc20Abi,
        functionName: 'allowance',
        args: [cardholder.address, deployed.spender],
      })) === 0n,
      'no standing allowance to the spender',
    )
    step(
      5,
      `Public spend: ${PUBLIC_SPENDS} single L1 transactions paid ${destination.label}, submit to receipt ${publicMs.join(', ')} ms (median ${median(publicMs)})`,
    )

    // A key scoped to the spender cannot move funds anywhere else.
    const stranger = privateKeyToAccount(generatePrivateKey()).address
    const leakedTransfer = await providerL1
      .sendTransactionSync({
        calls: [
          {
            to: pathUsd,
            data: encodeFunctionData({
              abi: erc20Abi,
              functionName: 'transfer',
              args: [stranger, 1n],
            }),
          },
        ],
        feeToken: pathUsd,
      } as never)
      .then(
        () => 'succeeded',
        () => 'refused',
      )
    assert(
      leakedTransfer === 'refused',
      "the provider's key cannot transfer out of the cardholder's account",
    )
    const leakedSpend = await l1Public
      .simulateContract({
        account: cardholder,
        address: deployed.spender,
        abi: spenderAbi,
        functionName: 'spend',
        args: [
          cardSpend(
            deployed,
            { address: stranger, hint: 0n, label: 'stranger' },
            1n,
            ref('public.stranger'),
          ),
        ],
      })
      .then(
        () => 'succeeded',
        () => 'reverted',
      )
    assert(leakedSpend === 'reverted', 'a spend to an address outside the program reverts')
    step(
      6,
      "The provider's key cannot transfer out, and a spend to an address outside the program reverts",
    )

    if (deployed.earn) {
      const live = await l1Public.readContract({
        address: deployed.earn.vault,
        abi: earnVaultAbi,
        functionName: 'previewWithdraw',
        args: [SPEND],
      })
      const maxShares = live + (live * SHARE_TOLERANCE_BPS) / 10_000n + 1n
      const sharesBefore = await balanceOf(deployed.earn.earnShare, cardholder.address)
      const before = await balanceOf(pathUsd, destination.address)
      const sent = await sendL1Sync(providerL1 as never, l1Public, [
        approve(deployed.earn.earnShare, maxShares),
        spendCall(cardSpend(deployed, destination, SPEND, ref('public.earn'), { maxShares })),
        approve(deployed.earn.earnShare, 0n),
      ])
      assert(sent.receipt.status === 'success', 'public spend from Earn settled')
      assert(
        (await balanceOf(pathUsd, destination.address)) - before === SPEND,
        `${destination.label} received exactly the spend from Earn`,
      )
      const burned = sharesBefore - (await balanceOf(deployed.earn.earnShare, cardholder.address))
      assert(burned === live, 'the spend burned exactly the live share cost')
      fund(destination.address, SPEND)
      step(
        7,
        `Public spend from Earn: ${formatUnits(burned, 6)} EarnShare redeemed exactly ${formatUnits(SPEND, 6)} pathUSD into ${destination.label}`,
      )
    }

    // ---------------------------------------------------------------------------------------------
    // Private spend: a Zone withdrawal to the router, settled on the L1 through the CardSettler
    // ---------------------------------------------------------------------------------------------
    const zoneClient = zoneClients(l1.chainId, zone)
    const userZone = await zoneClient(cardholder)
    const zoneBalance = (token: Address = pathUsd, blockNumber?: bigint) =>
      userZone.readContract({
        address: token,
        abi: erc20Abi,
        functionName: 'balanceOf',
        args: [cardholder.address],
        ...(blockNumber ? { blockNumber } : {}),
      } as never) as Promise<bigint>
    const depositFee = await portalRead<bigint>('calculateDepositFee')
    const bouncebackFee = await portalRead<bigint>('calculateBouncebackFee')
    async function depositIntoZone(token: Address, amount: bigint) {
      const start = await zoneBalance(token)
      if (token !== pathUsd)
        await write({
          address: token,
          abi: erc20Abi,
          functionName: 'approve',
          args: [portal, amount],
        })
      const hash = await userL1.zone.encryptedDeposit({
        amount,
        portalAddress: portal,
        recipient: cardholder.address,
        token,
        zoneId: zone!.zoneId,
      })
      const receipt = await l1Public.waitForTransactionReceipt({ hash, timeout: 180_000 })
      assert(receipt.status === 'success', 'the encrypted deposit succeeded')
      await Actions.zone.waitForTempoBlock(userZone, {
        pollingInterval: 500,
        tempoBlockNumber: receipt.blockNumber,
        timeout: 180_000,
      })
      await waitFor(
        'encrypted deposit',
        () => zoneBalance(token),
        (v) => v - start >= amount - depositFee,
        500,
      )
    }
    await depositIntoZone(pathUsd, DEPOSIT)
    const transferError = await userZone
      .simulateContract({
        account: cardholder,
        address: pathUsd,
        abi: zoneTokenAbi,
        functionName: 'transfer',
        args: [deployed.privateDestination.address, 1n],
      })
      .then(
        () => undefined,
        (error: unknown) => error,
      )
    assert(
      revertData(transferError) === toFunctionSelector('Unauthorized()'),
      'a Zone pathUSD transfer reverts with Unauthorized()',
    )
    step(
      8,
      `Cardholder deposited ${formatUnits(DEPOSIT, 6)} pathUSD privately into the Zone; Zone funds leave only by withdrawal`,
    )

    const zoneKeyPk = generatePrivateKey()
    const zoneKey = privateKeyToAccount(zoneKeyPk)
    const userZoneReceipts = await zoneClient(cardholder, true)
    const zoneTokens = [pathUsd, ...(deployed.earn ? [deployed.earn.earnShare] : [])]
    await userZoneReceipts.accessKey.authorizeSync({
      accessKey: { accessKeyAddress: zoneKey.address, keyType: 'secp256k1' },
      expiry: Math.floor(Date.now() / 1000) + 86_400,
      limits: zoneTokens.map((token) => ({ token, limit: 1_000_000_000n, period: 30 * 86_400 })),
      scopes: [
        ...zoneTokens.map((token) => ({
          address: token,
          selector: 'approve(address,uint256)',
          recipients: [outbox],
        })),
        {
          address: outbox,
          selector: 'requestWithdrawal(address,address,uint128,bytes32,uint64,address,bytes,bytes)',
        },
      ],
      feeToken: pathUsd,
    } as never)
    step(9, `Cardholder authorized ${provider.name}'s Zone key, scoped to the outbox`)
    const providerZone: ZoneClient = await zoneClient(
      Account.fromSecp256k1(zoneKeyPk, { access: cardholder.address }) as never,
      true,
    )
    const withdrawalFee = await userZone.readContract({
      address: outbox,
      abi: outboxAbi,
      functionName: 'calculateWithdrawalFee',
      args: [CALLBACK_GAS],
    })
    const change = depositFee + bouncebackFee + 1n

    async function callbackData(spend: CardSpendArgs, maxInput: bigint) {
      const recipient = await Actions.zone.encryptedDeposit.prepareRecipient(l1Public, {
        recipient: cardholder.address,
        sender: deployed.router,
        portalAddress: portal,
        zoneId: zone!.zoneId,
      })
      return encodeAbiParameters(spendDataType, [
        {
          op: OP_SPEND,
          settler: deployed.settler,
          maxInput,
          settlerData: encodeAbiParameters(cardSpendType, [spend]),
          zoneReturn: {
            keyIndex: recipient.keyIndex,
            encrypted: {
              ephemeralPubkeyX: recipient.encrypted.ephemeralPubkeyX,
              ephemeralPubkeyYParity: recipient.encrypted.ephemeralPubkeyYParity,
              ciphertext: recipient.encrypted.ciphertext,
              nonce: recipient.encrypted.nonce,
              tag: recipient.encrypted.tag,
            },
            refundRecipient,
            maxDepositFee: depositFee,
          },
        },
      ])
    }
    const requestWithdrawal = (token: Address, amount: bigint, data: Hex) =>
      providerZone.sendTransactionSync({
        calls: [
          {
            to: token,
            data: encodeFunctionData({
              abi: erc20Abi,
              functionName: 'approve',
              args: [outbox, amount + withdrawalFee],
            }),
          },
          {
            to: outbox,
            data: encodeFunctionData({
              abi: outboxAbi,
              functionName: 'requestWithdrawal',
              args: [
                token,
                deployed.router,
                amount,
                zeroHash,
                CALLBACK_GAS,
                cardholder.address,
                data,
                '0x',
              ],
            }),
          },
        ],
        feeToken: pathUsd,
      } as never)
    const settled = (spendRef: Hex, fromBlock: bigint) =>
      l1Public.getContractEvents({
        address: deployed.settler,
        abi: settlerAbi,
        eventName: 'SpendSettled',
        args: { ref: spendRef },
        fromBlock,
      })

    const to = deployed.privateDestination
    const zoneBefore = await zoneBalance()
    const destinationBefore = await balanceOf(pathUsd, to.address)
    const fromBlock = await l1Public.getBlockNumber()
    const privateRef = ref('private.1')
    const data = await callbackData(cardSpend(deployed, to, SPEND, privateRef), SPEND)
    const requested = performance.now()
    const request = await requestWithdrawal(pathUsd, SPEND + change, data)
    const zoneReceiptMs = since(requested)
    const accepted = performance.now()
    assert(request.status === 'success', "the provider's Zone key requested the spend")
    step(
      10,
      `${provider.name} requested a ${formatUnits(SPEND, 6)} pathUSD private spend, ${(data.length - 2) / 2}-byte callback, Zone receipt in ${zoneReceiptMs} ms`,
    )
    const events = await waitFor(
      'settlement on L1',
      () => settled(privateRef, fromBlock),
      (found) => found.length > 0,
      100,
    )
    const l1SettlementMs = since(accepted)
    const receipt = await l1Public.getTransactionReceipt({ hash: events[0]!.transactionHash })
    assert(
      (await balanceOf(pathUsd, to.address)) - destinationBefore === SPEND,
      `${to.label} received exactly the spend`,
    )
    const [spent] = parseEventLogs({
      abi: routerAbi,
      eventName: 'Spent',
      logs: receipt.logs.filter((l) => isAddressEqual(l.address, deployed.router)),
    })
    assert(
      spent && spent.args.used === SPEND && spent.args.change === change,
      'the router used exactly the spend and returned the change',
    )
    assert(
      !names(receipt.logs, cardholder.address),
      'no L1 log of the settlement names the cardholder',
    )
    fund(to.address, SPEND)
    step(
      11,
      `Settled on the L1 in ${l1SettlementMs} ms after the Zone receipt: ${to.label} paid, change returned, and none of the ${receipt.logs.length} logs names the cardholder`,
    )
    const fee =
      zoneBefore -
      SPEND -
      change -
      withdrawalFee -
      (await zoneBalance(pathUsd, request.blockNumber))
    assert(
      fee >= 0n,
      'the request took no more than its amount, withdrawal fee and transaction fee',
    )
    await waitFor(
      'the Zone balance after the spend and its change',
      () => zoneBalance(),
      (v) => v === zoneBefore - SPEND - withdrawalFee - fee - depositFee,
    )
    step(
      12,
      `Private balance down exactly the spend and fees (withdrawal ${formatUnits(withdrawalFee, 6)}, change deposit ${formatUnits(depositFee, 6)}, Zone tx ${formatUnits(fee, 6)})`,
    )

    // A private spend into a destination the program refuses for it bounces back into the Zone.
    const refused = deployed.refusedPrivateDestination
    const bounceBefore = await zoneBalance()
    const refusedBefore = await balanceOf(pathUsd, refused.address)
    const bounceFrom = await l1Public.getBlockNumber()
    const bounceRef = ref('private.refused')
    const bounce = await requestWithdrawal(
      pathUsd,
      SPEND + change,
      await callbackData(cardSpend(deployed, refused, SPEND, bounceRef), SPEND),
    )
    assert(bounce.status === 'success', 'the refused spend was requested in the Zone')
    const bounceFee =
      bounceBefore -
      SPEND -
      change -
      withdrawalFee -
      (await zoneBalance(pathUsd, bounce.blockNumber))
    const [processed] = await waitFor(
      'the portal processing the refused spend',
      () =>
        l1Public.getContractEvents({
          address: portal,
          abi: portalEventsAbi,
          eventName: 'WithdrawalProcessed',
          args: { to: deployed.router, senderTag: withdrawalRequested(bounce).senderTag },
          fromBlock: bounceFrom,
        }),
      (found) => found.length > 0,
      250,
    )
    assert(
      processed!.args.callbackSuccess === false,
      'the router callback reverted for the refused destination',
    )
    assert((await settled(bounceRef, bounceFrom)).length === 0, 'the refused spend settled nothing')
    assert(
      (await balanceOf(pathUsd, refused.address)) === refusedBefore,
      `${refused.label} received nothing`,
    )
    await waitFor(
      'the bounce back in the Zone',
      () => zoneBalance(),
      (v) => v === bounceBefore - withdrawalFee - bounceFee,
    )
    step(
      13,
      `A private spend into ${refused.label} bounced: the callback failed on the L1, nothing paid, all ${formatUnits(SPEND + change, 6)} pathUSD back in the Zone`,
    )

    let n = 14
    if (deployed.earn) {
      const earnShare = deployed.earn.earnShare
      const l1Shares = await balanceOf(earnShare, cardholder.address)
      await depositIntoZone(earnShare, l1Shares)
      const live = await l1Public.readContract({
        address: deployed.earn.vault,
        abi: earnVaultAbi,
        functionName: 'previewWithdraw',
        args: [SPEND],
      })
      const maxShares = live + (live * SHARE_TOLERANCE_BPS) / 10_000n + 1n
      const input = maxShares + change
      const sharesBefore = await zoneBalance(earnShare)
      const destBefore = await balanceOf(pathUsd, to.address)
      const earnFrom = await l1Public.getBlockNumber()
      const earnRef = ref('private.earn')
      const earnRequest = await requestWithdrawal(
        earnShare,
        input,
        await callbackData(cardSpend(deployed, to, SPEND, earnRef, { maxShares }), maxShares),
      )
      assert(earnRequest.status === 'success', 'the private Earn spend was requested')
      const [earnEvent] = await waitFor(
        'Earn settlement on L1',
        () => settled(earnRef, earnFrom),
        (found) => found.length > 0,
        250,
      )
      const earnReceipt = await l1Public.getTransactionReceipt({ hash: earnEvent!.transactionHash })
      assert(
        (await balanceOf(pathUsd, to.address)) - destBefore === SPEND,
        `${to.label} received exactly the spend from Earn`,
      )
      assert(
        !names(earnReceipt.logs, cardholder.address),
        'no L1 log of the Earn settlement names the cardholder',
      )
      const consumed = (earnEvent!.args as { inputConsumed: bigint }).inputConsumed
      assert(consumed === live, 'the settler burned exactly the live share cost')
      const after = await waitFor(
        'EarnShare change back in the Zone',
        () => zoneBalance(earnShare),
        (v) => v > sharesBefore - input - withdrawalFee,
      )
      assert(
        sharesBefore - after <= consumed + withdrawalFee + depositFee,
        'the Zone paid only the burned shares and fees',
      )
      fund(to.address, SPEND)
      step(
        n++,
        `Private spend from Earn: ${formatUnits(consumed, 6)} EarnShare redeemed ${formatUnits(SPEND, 6)} pathUSD into ${to.label}, unused shares back in the Zone, no log names the cardholder`,
      )
    }

    // ---------------------------------------------------------------------------------------------
    // The provider's own back office
    // ---------------------------------------------------------------------------------------------
    n = await provider.settle(ctx, deployed, n)

    const report = {
      provider: provider.name,
      earn: withEarn,
      publicSubmitToReceiptMs: publicMs,
      zoneRequestToZoneReceiptMs: zoneReceiptMs,
      zoneReceiptToL1SettlementMs: l1SettlementMs,
      callbackBytes: (data.length - 2) / 2,
    }
    writeFileSync(
      resolve(cardsRoot, `reports/cards-e2e-${provider.name}.json`),
      `${JSON.stringify(report, null, 2)}\n`,
    )
    console.log(`cards e2e (${provider.name}${withEarn ? ', earn' : ''}): all checks passed`)
  } finally {
    await Promise.allSettled([zone?.container.stop(), l1.container.stop()])
  }
}

main().catch((error) => {
  console.error(error)
  process.exit(1)
})
