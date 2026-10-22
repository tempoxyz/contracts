import { spawnSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { basename, resolve } from 'node:path'
import { deployFactoryReleaseScriptAbi, deployLocalEarnScriptAbi } from '@tempoxyz/earn/abis'
import { foundryProcessEnvironment } from '@tempoxyz/earn/deployments/node'
import {
  encodeFunctionData,
  getAddress,
  getContractAddress,
  type Abi,
  type Address,
  type ContractFunctionArgs,
  type ContractFunctionName,
  type Hex,
} from 'viem'

import * as Config from './config.js'
import * as Network from './network.js'

/** One transaction-sized fixture step: a typed call of one Foundry script entry point. */
export type Step = StepOptions & {
  /** `<script>.<entry point>`, for diagnostics. */
  name: string
  /** `<path>/<script>.s.sol:<contract>`. */
  target: string
  /** The entry point's calldata; Forge names its broadcast `<selector>-latest.json`. */
  calldata: Hex
}

export type StepOptions = {
  /**
   * Uses Forge's raw gas estimate: for large CREATE steps a 200% multiplier can exceed Tempo's 30M
   * transaction cap even when the deployment itself fits comfortably.
   */
  rawGasEstimate?: boolean
  /** Picks the contract this step deployed when the first candidate may not be it. */
  resolveAddress?(context: AddressContext): Promise<Address>
}

type AddressContext = {
  /** Distinct candidates: the receipt's, the broadcast's, then the deployer-nonce prediction. */
  candidates: readonly Address[]
  client: ReturnType<typeof Network.createClient>
}

/**
 * Binds a Foundry script to its generated ABI from `@tempoxyz/earn/abis`. The returned function
 * makes the step that calls one entry point with arguments typed by the Solidity signature.
 */
export function script<const abi extends Abi>(target: string, abi: abi) {
  const name = basename(target.split(':')[0]!).replace(/\.s\.sol$/, '')
  return <const functionName extends ContractFunctionName<abi, 'nonpayable'>>(
    functionName: functionName,
    args: ContractFunctionArgs<abi, 'nonpayable', functionName>,
    options: StepOptions = {},
  ): Step => ({
    ...options,
    name: `${name}.${functionName}`,
    target,
    calldata: encodeFunctionData({ abi, functionName, args } as never),
  })
}

/** Binds `localnet/foundry/script/<name>.s.sol:<name>Script`. */
export function fixtureScript<const abi extends Abi>(name: string, abi: abi) {
  return script(`localnet/foundry/script/${name}.s.sol:${name}Script`, abi)
}

/** The shared factory release, one CREATE per entry point for Tempo batches. */
export const release = script(
  'script/deploy/DeployFactoryRelease.s.sol:DeployFactoryReleaseScript',
  deployFactoryReleaseScriptAbi,
)

/** Engine-independent fixture steps; each engine module binds its own venue script. */
export const earnFixture = fixtureScript('DeployLocalEarn', deployLocalEarnScriptAbi)

export type Receipt = {
  blockNumber: bigint
  broadcastContractAddress?: Address | null
  contractAddress?: Address | null
  gasUsed: bigint
  transactionHash: Hex
}

export async function deploy(options: deploy.Options) {
  const nonce = await options.client.getTransactionCount({ address: options.account })
  const predictedAddress = getContractAddress({ from: options.account, nonce: BigInt(nonce) })
  const receipt = await run(options)
  const address = await resolveDeploymentAddress(options, receipt, predictedAddress)
  const code = await options.client.getCode({ address })
  if (!code || code === '0x') {
    throw new Error(`${options.step.name} did not deploy code at ${address}`)
  }
  return { address, receipt }
}

export declare namespace deploy {
  type Options = run.Options & { account: Address }
}

export type Deployment = Awaited<ReturnType<typeof deploy>>

export async function run(options: run.Options) {
  const { step } = options
  const latest = () => readLatest(options.broadcastDirectory, options.chainId, step)
  const previous = latest()
  const forge = spawnForge(
    [
      'script',
      step.target,
      '--sig',
      step.calldata,
      '--network',
      'tempo',
      '--rpc-url',
      options.rpcUrl,
      '--broadcast',
    ],
    // Only the deployer key reaches Forge; every other input is typed calldata.
    foundryProcessEnvironment({ ...process.env, DEPLOYER_PRIVATE_KEY: options.privateKey }),
    options.broadcastDirectory,
    step.rawGasEstimate,
  )
  if (forge.error || forge.status !== 0) {
    const recovered = latest()
    if (recovered?.hash && recovered.hash !== previous?.hash) {
      const recoveredReceipt = await options.client
        .getTransactionReceipt({ hash: recovered.hash })
        .catch(() => undefined)
      if (recoveredReceipt?.status === 'success') {
        return receiptFrom(recoveredReceipt, recovered.contractAddress)
      }
    }
    reportOutput(step.name, `${step.name} failed`, forge)
    await reportFailure(options.client, latest()?.hash, previous?.hash)
    throw (
      forge.error ??
      new Error(
        `Forge exited with status ${forge.status ?? 'unknown'}${forge.signal ? ` (${forge.signal})` : ''}`,
      )
    )
  }

  const broadcast = latest()
  if (!broadcast?.hash || broadcast.contents === previous?.contents) {
    throw new Error(`Forge did not write a new broadcast transaction for ${step.name}`)
  }
  const receipt = await options.client.getTransactionReceipt({ hash: broadcast.hash })
  if (receipt.status !== 'success') {
    throw new Error(`Forge transaction ${broadcast.hash} reverted during ${step.name}`)
  }
  return receiptFrom(receipt, broadcast.contractAddress)
}

export declare namespace run {
  type Options = {
    broadcastDirectory: string
    chainId: number
    client: ReturnType<typeof Network.createClient>
    privateKey: Hex
    rpcUrl: string
    step: Step
  }
}

/**
 * Executes one shared profile-lifecycle Forge step against the disposable chain: Tempo batch flags
 * and this environment's private broadcast directory.
 */
export function runLifecycleStep(step: LifecycleStep, broadcastDirectory: string) {
  const forge = spawnForge(
    step.arguments,
    step.environment,
    broadcastDirectory,
    step.rawGasEstimate,
  )
  if (forge.error || forge.status !== 0) {
    reportOutput(step.action.id, `Shared ${step.action.id} step failed`, forge)
    throw forge.error ?? new Error(`Forge exited with status ${forge.status ?? 'unknown'}`)
  }
}

type LifecycleStep = {
  action: { id: string }
  arguments: string[]
  environment: Record<string, string>
  /** Set by the shared step for a large CREATE; see `Step.rawGasEstimate`. */
  rawGasEstimate: boolean
}

/** Runs Forge from the repository root with Tempo batch flags and a private broadcast directory. */
function spawnForge(
  args: readonly string[],
  environment: NodeJS.ProcessEnv,
  broadcastDirectory: string,
  rawGasEstimate: boolean | undefined,
) {
  return spawnSync(
    'forge',
    [
      ...args,
      '--tempo.fee-token',
      Config.address.pathUsd,
      '--batch',
      '--gas-estimate-multiplier',
      rawGasEstimate ? '100' : '200',
      '--disable-labels',
    ],
    {
      cwd: Config.root,
      encoding: 'utf8',
      env: { ...environment, FOUNDRY_BROADCAST: broadcastDirectory },
      maxBuffer: 32 * 1024 * 1024,
    },
  )
}

function readLatest(directory: string, chainId: number, step: Step) {
  try {
    const script = basename(step.target.split(':')[0]!)
    const path = resolve(
      directory,
      script,
      String(chainId),
      `${step.calldata.slice(2, 10)}-latest.json`,
    )
    const contents = readFileSync(path, 'utf8')
    const broadcast = JSON.parse(contents) as {
      transactions?: { hash?: Hex | null; contractAddress?: Address | null }[]
    }
    const transaction = broadcast.transactions
      ?.slice()
      .reverse()
      .find((candidate) => candidate.hash)
    return {
      contents,
      hash: transaction?.hash ?? undefined,
      contractAddress: transaction?.contractAddress ?? undefined,
    }
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return undefined
    throw error
  }
}

function receiptFrom(
  receipt: {
    blockNumber: bigint
    contractAddress?: Address | null
    gasUsed: bigint
    transactionHash: Hex
  },
  broadcastContractAddress?: Address,
): Receipt {
  // The live receipt is authoritative when Tempo reports the created address. Foundry's
  // broadcast artifact remains the fallback because some batched CREATE2 receipts omit it.
  const contractAddress = receipt.contractAddress ?? broadcastContractAddress
  return {
    blockNumber: receipt.blockNumber,
    ...(broadcastContractAddress ? { broadcastContractAddress } : {}),
    ...(contractAddress ? { contractAddress } : {}),
    gasUsed: receipt.gasUsed,
    transactionHash: receipt.transactionHash,
  }
}

async function resolveDeploymentAddress(
  options: deploy.Options,
  receipt: Receipt,
  predictedAddress: Address,
): Promise<Address> {
  const candidates = [
    receipt.contractAddress,
    receipt.broadcastContractAddress,
    predictedAddress,
  ].filter((candidate, index, all): candidate is Address => {
    return Boolean(candidate) && all.findIndex((entry) => entry === candidate) === index
  })
  if (options.step.resolveAddress) {
    return options.step.resolveAddress({ candidates, client: options.client })
  }
  return getAddress(candidates[0] ?? predictedAddress)
}

function reportOutput(
  step: string,
  message: string,
  output: { stderr?: Buffer | string | null; stdout?: Buffer | string | null },
) {
  const contents = [output.stdout, output.stderr]
    .map((value) => value?.toString().trim())
    .filter(Boolean)
    .join('\n')
  console.error(`\n✗ ${message}`)
  console.error(`\n----- Forge output: ${step} -----`)
  console.error(contents || '(no output captured)')
  console.error('----- End Forge output -----\n')
}

async function reportFailure(
  client: ReturnType<typeof Network.createClient>,
  hash: Hex | undefined,
  previousHash: Hex | undefined,
) {
  try {
    if (!hash || hash === previousHash) {
      console.error('No new Forge transaction was broadcast; receipt diagnostics unavailable.')
      return
    }
    const [receipt, transaction] = await Promise.all([
      client.getTransactionReceipt({ hash }),
      client.getTransaction({ hash }),
    ])
    console.error(
      `Failed receipt ${hash}: status=${receipt.status}, type=${transaction.type}, gas=${transaction.gas}, gasUsed=${receipt.gasUsed}, block=${receipt.blockNumber}, feeToken=${'feeToken' in transaction ? String(transaction.feeToken) : 'none'}`,
    )
    const trace = (await client.request({
      method: 'debug_traceTransaction',
      params: [hash, { disableMemory: true, disableStack: true, disableStorage: true }],
    } as never)) as {
      returnValue?: Hex
      structLogs?: {
        depth: number
        error?: string
        gas: number
        gasCost: number
        op: string
        pc: number
      }[]
    }
    const tail = trace.structLogs?.slice(-8).map(({ depth, error, gas, gasCost, op, pc }) => ({
      depth,
      error,
      gas,
      gasCost,
      op,
      pc,
    }))
    console.error(
      `Failed trace tail: ${tail ? JSON.stringify(tail) : (trace.returnValue ?? 'no trace detail')}`,
    )
  } catch (error) {
    console.error(
      `Could not read failed transaction diagnostics: ${error instanceof Error ? error.message : String(error)}`,
    )
  }
}
