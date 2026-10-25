import { erc20Abi, formatUnits, parseUnits, getAddress, type Address, type Hex } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { createClient, EarnShares } from 'viem/tempo'

import { configuredTempoNetworkChain, deploymentEnvironmentId } from '../chain/tempo.js'
import { requireCode } from '../chain/inspect.js'
import { configuredRpcTransport, envPrivateKey } from '../chain/runtime.js'
import { earnVaultAbi } from '../abis/index.js'
import { quoteEarnDeposit, readEngineVenue } from '../modules/engines/index.js'
import { requiredOutput } from '../modules/module.js'
import type { EarnDeploymentProfile } from './profile.js'
import type { EarnDeploymentRecord } from './record.js'
import { inspectStackBinding } from './stack.js'

const defaultSlippageBps = 50
const transactionTimeout = 180_000

export type ProfileDepositOptions = {
  account?: string | undefined
  assets: string
  broadcast: boolean
  environment: NodeJS.ProcessEnv
  profile: EarnDeploymentProfile
  receiver?: string | undefined
  record: EarnDeploymentRecord
  rpcUrl: string
  slippageBps?: number | undefined
}

export type ProfileDepositResult = {
  state: 'preview' | 'deposited'
  deploymentId: string
  depositor: Address
  receiver: Address
  asset: { address: Address; symbol: string; decimals: number }
  earnShare: { address: Address; symbol: string; decimals: number }
  assets: string
  expectedEarnShares: string
  minimumEarnShares: string
  slippageBps: number
  balanceBefore: string
  depositsPaused: boolean
  remainingDepositCapacity: string
  depositTransactionHash?: Hex | undefined
  depositedEarnShares?: string | undefined
  earnShareBalanceAfter?: string | undefined
  accountingAligned?: boolean | undefined
}

/**
 * Previews or submits a profile-backed Earn deposit, quoted through the engine's own module.
 * Broadcast mode uses Tempo's atomic approval-and-deposit client action so this operational helper
 * matches public E2E.
 */
export async function depositEarnProfile(
  options: ProfileDepositOptions,
): Promise<ProfileDepositResult> {
  const { profile, record } = options
  const engineKind = profile.engine.kind
  const recorded = record.addresses as Record<string, Address>
  const contracts = {
    asset: requiredOutput(recorded, 'asset'),
    engine: requiredOutput(recorded, 'engine'),
    earnShare: requiredOutput(recorded, 'earnShare'),
    earnVault: requiredOutput(recorded, 'earnVault'),
    earnFees: requiredOutput(recorded, 'earnFees'),
  }
  const assetDecimals = record.assetDecimals
  const assets = parseTokenAmount(options.assets, assetDecimals, '--assets')
  if (assets <= 0n) throw new Error('--assets must be greater than zero')
  const slippageBps = options.slippageBps ?? defaultSlippageBps
  if (!Number.isInteger(slippageBps) || slippageBps < 0 || slippageBps > 10_000) {
    throw new Error('--slippage-bps must be an integer from 0 through 10000')
  }

  const deployerKey = envPrivateKey(options.environment, 'DEPLOYER_PRIVATE_KEY')
  const signingAccount = deployerKey ? privateKeyToAccount(deployerKey) : undefined
  const depositor = options.account ? getAddress(options.account) : signingAccount?.address
  if (!depositor) throw new Error('--account or DEPLOYER_PRIVATE_KEY is required')
  const receiver = options.receiver ? getAddress(options.receiver) : depositor
  if (options.broadcast && !signingAccount) {
    throw new Error('DEPLOYER_PRIVATE_KEY is required with --broadcast')
  }
  if (signingAccount && signingAccount.address !== depositor) {
    throw new Error('--account does not match DEPLOYER_PRIVATE_KEY')
  }

  const chain = configuredTempoNetworkChain({
    id: deploymentEnvironmentId(profile.chainId),
    chainId: profile.chainId,
    rpcUrl: options.rpcUrl,
    feeToken: contracts.asset,
  })
  const transport = configuredRpcTransport({ url: options.rpcUrl })
  const publicClient = createClient({ chain, transport })
  const [chainId, genesis] = await Promise.all([
    publicClient.getChainId(),
    publicClient.getBlock({ blockNumber: 0n }),
  ])
  if (chainId !== profile.chainId || chainId !== record.target.chainId) {
    throw new Error(`RPC chain ${chainId} does not match profile chain ${profile.chainId}`)
  }
  if (!genesis.hash || genesis.hash.toLowerCase() !== record.target.genesisHash.toLowerCase()) {
    throw new Error('RPC genesis hash does not match the generated deployment record')
  }
  const venue =
    'venue' in profile.engine
      ? profile.engine.venue
      : await readEngineVenue(publicClient, engineKind, contracts.engine)
  await requireCode(publicClient, { ...contracts, venue })
  await inspectStackBinding(publicClient, { ...contracts, engineKind, venue })

  const [
    assetSymbol,
    liveAssetDecimals,
    earnShareSymbol,
    earnShareDecimals,
    balanceBefore,
    expectedEarnShares,
    depositsPaused,
    remainingDepositCapacity,
  ] = await Promise.all([
    publicClient.readContract({ address: contracts.asset, abi: erc20Abi, functionName: 'symbol' }),
    publicClient.readContract({
      address: contracts.asset,
      abi: erc20Abi,
      functionName: 'decimals',
    }),
    publicClient.readContract({
      address: contracts.earnShare,
      abi: erc20Abi,
      functionName: 'symbol',
    }),
    publicClient.readContract({
      address: contracts.earnShare,
      abi: erc20Abi,
      functionName: 'decimals',
    }),
    publicClient.readContract({
      address: contracts.asset,
      abi: erc20Abi,
      functionName: 'balanceOf',
      args: [depositor],
    }),
    quoteEarnDeposit(publicClient, { engineKind, contracts: { ...contracts, venue } }, assets),
    publicClient.readContract({
      address: contracts.earnVault,
      abi: earnVaultAbi,
      functionName: 'depositsPaused',
    }),
    publicClient.readContract({
      address: contracts.earnVault,
      abi: earnVaultAbi,
      functionName: 'remainingDepositCapacity',
    }),
  ])
  if (liveAssetDecimals !== assetDecimals) {
    throw new Error('Asset decimals do not match the generated deployment record')
  }
  if (expectedEarnShares <= 0n) throw new Error('Deposit preview returned zero EarnShare')
  const minimumEarnShares = EarnShares.minimumOutput(expectedEarnShares, slippageBps)

  const baseResult: ProfileDepositResult = {
    state: 'preview',
    deploymentId: profile.id,
    depositor,
    receiver,
    asset: { address: contracts.asset, symbol: assetSymbol, decimals: assetDecimals },
    earnShare: {
      address: contracts.earnShare,
      symbol: earnShareSymbol,
      decimals: earnShareDecimals,
    },
    assets: assets.toString(),
    expectedEarnShares: expectedEarnShares.toString(),
    minimumEarnShares: minimumEarnShares.toString(),
    slippageBps,
    balanceBefore: balanceBefore.toString(),
    depositsPaused,
    remainingDepositCapacity: remainingDepositCapacity.toString(),
  }
  if (!options.broadcast) return baseResult
  if (depositsPaused) throw new Error('EarnVault deposits are paused')
  if (assets > remainingDepositCapacity) {
    throw new Error('Deposit exceeds the EarnVault remaining managed-asset capacity')
  }
  if (balanceBefore <= assets) {
    throw new Error(
      `Depositor needs more than ${formatUnits(assets - balanceBefore, assetDecimals)} ${assetSymbol}; leave additional ${assetSymbol} for Tempo transaction fees`,
    )
  }

  const depositorClient = createClient({ account: signingAccount!, chain, transport })
  const depositTransactionHash = await depositorClient.earn.deposit({
    account: signingAccount!,
    assetAmount: assets,
    recipient: receiver,
    shareAmountMin: minimumEarnShares,
    vault: contracts.earnVault,
  })
  const receipt = await publicClient.waitForTransactionReceipt({
    hash: depositTransactionHash,
    timeout: transactionTimeout,
  })
  const depositEvent = depositorClient.earn.deposit.extractEvent(receipt.logs, {
    vault: contracts.earnVault,
  })
  const [earnShareBalanceAfter, accountingAligned] = await Promise.all([
    publicClient.readContract({
      address: contracts.earnShare,
      abi: erc20Abi,
      functionName: 'balanceOf',
      args: [receiver],
    }),
    publicClient.readContract({
      address: contracts.earnVault,
      abi: earnVaultAbi,
      functionName: 'isAccountingAligned',
    }),
  ])
  return {
    ...baseResult,
    state: 'deposited',
    depositTransactionHash,
    depositedEarnShares: depositEvent.args.earnShares.toString(),
    earnShareBalanceAfter: earnShareBalanceAfter.toString(),
    accountingAligned,
  }
}

function parseTokenAmount(value: string, decimals: number, flag: string) {
  const match = /^(\d+)(?:\.(\d+))?$/.exec(value)
  if (!match || (match[2]?.length ?? 0) > decimals) {
    throw new Error(`${flag} must be a decimal amount with at most ${decimals} decimal places`)
  }
  return parseUnits(value, decimals)
}
