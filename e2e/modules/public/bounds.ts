import { BaseError, ContractFunctionRevertedError, type Abi, type Address, type Hex } from 'viem'
import { simulateCalls } from 'viem/actions'
import {
  earnVaultAbi,
  erc4626EngineAbi,
  propAMMEngineAbi,
  vedaEngineAbi,
} from '@tempoxyz/contracts/abis'
import type { E2eContext } from '../../harness/context.js'
import { assert } from '../../harness/support/utils.js'

const boundAbis: readonly Abi[] = [earnVaultAbi, erc4626EngineAbi, propAMMEngineAbi, vedaEngineAbi]
const boundErrors = boundAbis.flatMap((abi) => abi.filter((item) => item.type === 'error'))

// Earn's atomic builders supply encoded calldata and its ABI for simulation error decoding.
type BoundCall = {
  abi: Abi
  args: readonly unknown[]
  data: Hex
  functionName: string
  to: Address
}

type CallResult = { status: string; error?: unknown }

/** Rejects unrelated failures; the same calls must succeed when only their output bound changes. */
export function assertBoundResults(
  rejected: readonly CallResult[],
  relaxed: readonly CallResult[],
  expectedErrors: readonly string[],
) {
  assert(
    rejected.length > 0 && rejected.slice(0, -1).every((result) => result.status === 'success'),
    'bound setup call failed',
  )
  const failure = rejected.at(-1)
  assert(
    failure?.status === 'failure' && failure.error instanceof BaseError,
    'bound call did not fail with a contract error',
  )
  const cause = failure.error.walk((error) => error instanceof ContractFunctionRevertedError)
  assert(
    cause instanceof ContractFunctionRevertedError &&
      expectedErrors.includes(cause.data?.errorName ?? ''),
    `bound call did not decode ${expectedErrors.join(' or ')}`,
  )
  assert(
    relaxed.length === rejected.length && relaxed.every((result) => result.status === 'success'),
    'same operation with relaxed bound did not succeed',
  )
}

/** Simulates atomic approvals and the bound-sensitive call without changing live state. */
export async function simulateBound(
  context: E2eContext,
  options: {
    calls: readonly BoundCall[]
    relaxedCalls: readonly BoundCall[]
    errors: readonly string[]
  },
) {
  const blockNumber = await context.l1Public.getBlockNumber({ cacheTime: 0 })
  const simulate = (calls: readonly BoundCall[]) =>
    simulateCalls(context.l1Public, {
      account: context.user.address,
      blockNumber,
      calls: calls.map((call) => ({
        ...call,
        abi: [...call.abi, ...boundErrors],
      })),
      validation: false,
    })
  const rejected = await simulate(options.calls)
  const relaxed = await simulate(options.relaxedCalls)
  assertBoundResults(rejected.results, relaxed.results, options.errors)
}
