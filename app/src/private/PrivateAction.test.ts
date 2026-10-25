import {
  ContractFunctionExecutionError,
  ContractFunctionRevertedError,
  encodeAbiParameters,
  encodeErrorResult,
  getAddress,
  type Address,
  type Hex,
} from 'viem'
import { zonePortalAbi } from '@tempoxyz/earn/abis'
import { Abis, Actions as TempoActions } from 'viem/tempo'
import { pathusd } from 'viem/tokens'
import { afterEach, expect, test, vi } from 'vitest'

import { hostedPrivateStack } from '../test/HostedCatalog.js'
import * as PrivateAction from './PrivateAction.js'

const viemActions = vi.hoisted(() => ({
  getGasPrice: vi.fn(async () => 1n),
  getTransactionCount: vi.fn(async () => 0),
}))

vi.mock('viem/actions', async (importOriginal) => ({
  ...(await importOriginal()),
  ...viemActions,
}))

const { deployment: registeredDeployment, earnRouter } = hostedPrivateStack()
const pathUsd = pathusd.addresses[42431]
const alternate = getAddress('0x0000000000000000000000000000000000000020')
const zone = {
  name: 'test-zone',
  id: 1,
  chainId: 421700001,
  rpcUrl: 'https://zone.example',
  portal: getAddress('0x5ad0000000000000000000000000000000000001'),
  messenger: getAddress('0x5A4d000000000000000000000000000000000000'),
  sequencers: [getAddress('0x0000000000000000000000000000000000000005')],
}
const deployment = {
  ...registeredDeployment,
  capabilities: { ...registeredDeployment.capabilities, deposit: true },
  contracts: { ...registeredDeployment.contracts, asset: pathUsd },
  expectedMetadata: {
    ...registeredDeployment.expectedMetadata,
    asset: { decimals: pathusd.decimals, name: pathusd.name, symbol: pathusd.symbol },
  },
  modes: {
    ...registeredDeployment.modes,
    private: { availability: 'available' as const, privateAsset: alternate },
  },
}

afterEach(() => {
  vi.restoreAllMocks()
})

const readyLiquidity = [false, true, true, 10_000_000n, 10_000_000n] as const

const blockTime = 1_800_000_100n
const conversionPool = getAddress('0x00000000000000000000000000000000000000b1')
const poolOracle = getAddress('0x00000000000000000000000000000000000000b2')
/** Latest L1 block time used to age the pool oracle's report. */
const freshBlock = async () => ({ timestamp: blockTime })

const actionId = `0x${'77'.repeat(32)}` as Hex

/** Stubs viem's deposit `prepare` with a callback refunding `refundRecipient`, Zone key index 7. */
function prepareDeposit(refundRecipient: Address) {
  const data = encodeAbiParameters(Abis.earnRouterCallbackData, [
    {
      actionId,
      flow: 0,
      minEarnShares: 1n,
      minOutputAmount: 0n,
      minVaultAssets: 1n,
      zoneReturn: {
        encrypted: {
          ciphertext: '0x1234',
          ephemeralPubkeyX: `0x${'22'.repeat(32)}`,
          ephemeralPubkeyYParity: 0,
          nonce: `0x${'33'.repeat(12)}`,
          tag: `0x${'44'.repeat(16)}`,
        },
        keyIndex: 7n,
        refundRecipient,
      },
    },
  ])
  return vi.spyOn(TempoActions.earn.privateDeposit, 'prepare').mockResolvedValue({
    actionId,
    amount: 5_000_000n,
    callbackGas: 10_000_000n,
    chainId: 42431,
    data,
    fallbackRecipient: refundRecipient,
    fromBlock: 1n,
    to: earnRouter,
    token: alternate,
    zoneId: zone.id,
  })
}

/**
 * Mocks L1 reads with the router's live pool status, a par oracle reported `oracleAge` seconds ago
 * against a one-day maximum, and a fixed value for every other read.
 */
function l1Reads(
  options: {
    liquidity?: readonly [boolean, boolean, boolean, bigint, bigint]
    oracleAge?: bigint
  } = {},
) {
  return vi.fn(async ({ functionName }: { functionName: string }) => {
    if (functionName === 'liquidityStatus') return options.liquidity ?? readyLiquidity
    if (functionName === 'pool') return conversionPool
    if (functionName === 'oracle') return poolOracle
    if (functionName === 'maxOracleAge') return 86_400n
    if (functionName === 'latestPrice')
      return [100_000_000n, blockTime - (options.oracleAge ?? 60n)]
    return 5_000_000n
  })
}

test('refuses a private action before the Zone withdrawal when the user is not admitted', async () => {
  const account = { address: getAddress('0x0000000000000000000000000000000000000009') }
  const requestWithdrawalSync = vi.fn()
  const prepare = prepareDeposit(account.address)
  const abi = zonePortalAbi
  const reverted = new ContractFunctionRevertedError({
    abi,
    data: encodeErrorResult({ abi, errorName: 'AccountNotAllowed', args: [account.address] }),
    functionName: 'depositEncrypted',
  })
  const simulateContract = vi.fn(async () => {
    throw new ContractFunctionExecutionError(reverted, {
      abi,
      args: [],
      contractAddress: zone.portal,
      functionName: 'depositEncrypted',
    })
  })

  await expect(
    PrivateAction.execute({
      account: account as never,
      action: 'deposit',
      amount: 5_000_000n,
      deployment,
      earnRouter,
      feeToken: pathUsd,
      flowId: 'unadmitted',
      l1Client: {
        getBlockNumber: vi.fn(async () => 1n),
        getBlock: freshBlock,
        readContract: l1Reads(),
        simulateContract,
      } as never,
      onTransaction: vi.fn(),
      zone,
      zoneClient: { zone: { requestWithdrawalSync } } as never,
    }),
  ).rejects.toThrow(`${account.address} is not admitted`)
  // The user is the refund and fallback recipient; the exact par swap bounds vault assets at the input.
  expect(prepare).toHaveBeenCalledWith(
    expect.anything(),
    expect.objectContaining({
      assetAmount: 5_000_000n,
      assetToken: alternate,
      gateway: earnRouter,
      portalAddress: zone.portal,
      recipient: account.address,
      tempoRefundRecipient: account.address,
      vault: deployment.contracts.earnVault,
      vaultAssetAmountMin: 5_000_000n,
      zoneId: zone.id,
    }),
  )
  expect(simulateContract).toHaveBeenCalledWith(
    expect.objectContaining({
      account: earnRouter,
      address: zone.portal,
      args: [deployment.contracts.earnShare, 1n, 7n, expect.anything(), account.address],
    }),
  )
  expect(requestWithdrawalSync).not.toHaveBeenCalled()
})

test('fails fast when L1 processes the Zone withdrawal but the router callback reverts', async () => {
  const accessKeyAddress = getAddress('0x0000000000000000000000000000000000000010')
  const keyAuthorization = { chainId: zone.chainId } as never
  const keyAuthorizationManager = {
    get: vi.fn(async () => keyAuthorization),
    remove: vi.fn(async () => undefined),
    set: vi.fn(async () => undefined),
  }
  const account = {
    address: getAddress('0x0000000000000000000000000000000000000009'),
    accessKeyAddress,
    keyAuthorizationManager,
    source: 'accessKey',
  }
  const senderTag = `0x${'11'.repeat(32)}` as Hex
  const transactionHash = `0x${'55'.repeat(32)}` as Hex
  const requestWithdrawalSync = vi.fn(async () => ({
    receipt: { transactionHash: `0x${'66'.repeat(32)}` as Hex },
    senderTag,
  }))
  const zoneClient = {
    chain: { id: zone.chainId },
    readContract: vi.fn(async () => 0n),
    // The Outbox charges no withdrawal fee.
    request: vi.fn(async () => `0x${'00'.repeat(32)}`),
    zone: { requestWithdrawalSync },
  }
  prepareDeposit(account.address)
  const getLogs = vi.fn(async () => [
    {
      args: { callbackSuccess: false },
      transactionHash,
    },
  ])
  const getTransactionReceipt = vi.fn()
  const l1Client = {
    getBlockNumber: vi.fn(async () => 1n),
    getLogs,
    getTransactionReceipt,
    getBlock: freshBlock,
    readContract: l1Reads(),
    simulateContract: vi.fn(async () => ({})),
  }
  const onTransaction = vi.fn()

  await expect(
    PrivateAction.execute({
      account: account as never,
      action: 'deposit',
      amount: 5_000_000n,
      deployment,
      earnRouter,
      feeToken: pathUsd,
      flowId: 'deposit',
      l1Client: l1Client as never,
      onTransaction,
      zone,
      zoneClient: zoneClient as never,
    }),
  ).rejects.toThrow(
    `The L1 withdrawal was processed, but the EarnRouter callback reverted in transaction ${transactionHash}.`,
  )

  expect(requestWithdrawalSync).toHaveBeenCalledWith(
    expect.objectContaining({ feeToken: pathUsd, keyAuthorization }),
  )
  expect(keyAuthorizationManager.remove).toHaveBeenCalledWith({
    accessKey: accessKeyAddress,
    address: account.address,
    chainId: zone.chainId,
  })

  expect(getLogs).toHaveBeenCalledWith(
    expect.objectContaining({
      address: zone.portal,
      args: { senderTag, to: earnRouter },
      fromBlock: 1n,
    }),
  )
  expect(getTransactionReceipt).not.toHaveBeenCalled()
  expect(onTransaction).toHaveBeenLastCalledWith(
    expect.objectContaining({
      environment: 'Tempo L1',
      hash: transactionHash,
      id: 'deposit-router-callback',
      status: 'error',
    }),
  )
})
