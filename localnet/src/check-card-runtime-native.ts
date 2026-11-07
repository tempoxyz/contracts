import assert from 'node:assert/strict'
import {
  BaseError,
  ContractFunctionRevertedError,
  erc20Abi,
  http,
  parseAbi,
  parseEventLogs,
  zeroAddress,
  zeroHash,
} from 'viem'
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts'
import { Actions, createClient, Store, http as zoneHttp } from 'viem/tempo'

import * as Config from './config.js'
import * as Network from './network.js'

const privateKey = generatePrivateKey()
const account = privateKeyToAccount(privateKey)
const recipient = privateKeyToAccount(generatePrivateKey()).address
const l1 = await Network.startL1(account.address)
let zone: Network.Zone | undefined
try {
  const client = createClient({
    account,
    chain: Network.chain(l1.chainId, l1.rpcUrl),
    transport: http(l1.rpcUrl),
  })
  await client.faucet.fundSync({ account: account.address })
  const { token } = await client.token.createSync({
    name: 'Runtime probe',
    symbol: 'RTP',
    currency: 'USD',
    feeToken: Config.address.pathUsd,
  })
  zone = await Network.startZone({
    client: l1.client,
    initialToken: token,
    l1Port: l1.port,
    privateKey,
  })
  const portalAbi = parseAbi([
    'function enableToken(address token)',
    'function currentDepositQueueHash() view returns (bytes32)',
    'function depositCount() view returns (uint64)',
    'function calculateDepositFee() view returns (uint128)',
    'event WithdrawalProcessed(address indexed to, bytes32 indexed senderTag, address token, uint128 amount, bool callbackSuccess)',
  ])
  await client.writeContractSync({
    address: zone.portal,
    abi: portalAbi,
    functionName: 'enableToken',
    args: [Config.address.pathUsd],
    feeToken: Config.address.pathUsd,
  })
  await Network.waitForToken(zone.publicRpcUrl, Config.address.pathUsd)
  const store = Store.memory()
  const zoneClient = createClient({
    account,
    chain: Network.chain(zone.chainId, zone.publicRpcUrl),
    transport: zoneHttp(zone.publicRpcUrl, { store }),
  })
  await zoneClient.zone.signAuthorizationToken({ account, zoneId: zone.id, store })
  const inbox = '0x1c00000000000000000000000000000000000001'
  const outbox = '0x1c00000000000000000000000000000000000002'
  const inboxAbi = parseAbi([
    'function tempoPortal() view returns (address)',
    'function processedDepositQueueHash() view returns (bytes32)',
    'function processedDepositNumber() view returns (uint64)',
  ])
  assert.equal(
    (
      await zoneClient.readContract({ address: inbox, abi: inboxAbi, functionName: 'tempoPortal' })
    ).toLowerCase(),
    zone.portal.toLowerCase(),
  )
  const fee = await client.readContract({
    address: zone.portal,
    abi: portalAbi,
    functionName: 'calculateDepositFee',
  })
  const hash = await client.zone.encryptedDeposit({
    amount: 100_000_000n,
    portalAddress: zone.portal,
    recipient: account.address,
    token: Config.address.pathUsd,
    zoneId: zone.id,
  })
  const deposit = await client.waitForTransactionReceipt({ hash })
  assert.equal(deposit.status, 'success')
  await Actions.zone.waitForTempoBlock(zoneClient, {
    tempoBlockNumber: deposit.blockNumber,
    timeout: 180_000,
  })
  await waitFor(
    async () =>
      (await zoneClient.readContract({
        address: Config.address.pathUsd,
        abi: erc20Abi,
        functionName: 'balanceOf',
        args: [account.address],
        account: account.address,
      })) ===
      100_000_000n - fee,
  )
  for (const [local, parent] of [
    ['processedDepositQueueHash', 'currentDepositQueueHash'],
    ['processedDepositNumber', 'depositCount'],
  ] as const)
    assert.equal(
      await zoneClient.readContract({ address: inbox, abi: inboxAbi, functionName: local }),
      await client.readContract({ address: zone.portal, abi: portalAbi, functionName: parent }),
    )
  console.log(
    'PASS native Inbox: canonical Portal, ECIES deposit, exact net credit and queue hash/count',
  )

  const outboxAbi = parseAbi([
    'function requestWithdrawal(address token,address to,uint128 amount,bytes32 memo,uint64 gasLimit,address fallbackRecipient,bytes data,bytes revealTo)',
    'function MAX_CALLBACK_DATA_SIZE() view returns (uint256)',
    'error InvalidFallbackRecipient()',
    'error ZeroAmountWithdrawal()',
    'error CallbackDataTooLarge()',
  ])
  assert.equal(
    await zoneClient.readContract({
      address: outbox,
      abi: outboxAbi,
      functionName: 'MAX_CALLBACK_DATA_SIZE',
    }),
    1024n,
  )
  for (const [errorName, amount, fallback, data] of [
    ['InvalidFallbackRecipient', 1n, zeroAddress, '0x'],
    ['ZeroAmountWithdrawal', 0n, account.address, '0x'],
    ['CallbackDataTooLarge', 1n, account.address, `0x${'ab'.repeat(1025)}`],
  ] as const) {
    await assert.rejects(
      zoneClient.simulateContract({
        account,
        address: outbox,
        abi: outboxAbi,
        functionName: 'requestWithdrawal',
        args: [Config.address.pathUsd, recipient, amount, zeroHash, 0n, fallback, data, '0x'],
      }),
      (error: unknown) => {
        const cause =
          error instanceof BaseError
            ? error.walk((entry) => entry instanceof ContractFunctionRevertedError)
            : undefined
        return cause instanceof ContractFunctionRevertedError && cause.data?.errorName === errorName
      },
    )
    console.log(`PASS native Outbox: ${errorName} (not enforced by ZoneOutboxSim)`)
  }
  const before = await client.readContract({
    address: Config.address.pathUsd,
    abi: erc20Abi,
    functionName: 'balanceOf',
    args: [recipient],
  })
  const fromBlock = await client.getBlockNumber()
  const withdrawal = await zoneClient.zone.requestWithdrawalSync({
    amount: 1_000_000n,
    fallbackRecipient: account.address,
    to: recipient,
    token: Config.address.pathUsd,
    feeToken: Config.address.pathUsd,
  })
  assert.equal(withdrawal.receipt.status, 'success')
  await waitFor(
    async () =>
      (await client.readContract({
        address: Config.address.pathUsd,
        abi: erc20Abi,
        functionName: 'balanceOf',
        args: [recipient],
      })) ===
      before + 1_000_000n,
  )
  const logs = await client.getLogs({ address: zone.portal, fromBlock })
  assert.equal(
    parseEventLogs({ abi: portalAbi, eventName: 'WithdrawalProcessed', logs }).filter(
      (entry) => entry.args.senderTag === withdrawal.senderTag && entry.args.amount === 1_000_000n,
    ).length,
    1,
  )
  console.log(
    'PASS native Outbox/Portal: actual withdrawal batch, transaction-bound senderTag and exact L1 delivery',
  )
} finally {
  await Promise.all([zone?.container.stop(), l1.container.stop()])
}

async function waitFor(check: () => Promise<boolean>) {
  const deadline = Date.now() + 180_000
  while (Date.now() < deadline) {
    if (await check()) return
    await new Promise((done) => setTimeout(done, 250))
  }
  throw new Error('Native runtime regression timed out')
}
