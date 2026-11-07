import { execFileSync } from 'node:child_process'
import type { Address, Hex, PublicClient } from 'viem'

import { isHostedDeploymentChain } from '../chain/tempo.js'
import { assertCreationReceipt, assertDirectCreationTransaction } from '../chain/creation.js'
import {
  assertFoundryProjectEnvironment,
  foundryProjectRoot,
  foundryVerificationEnvironment,
} from '../chain/foundry.js'
import type { FoundryStep } from '../modules/module.js'
import { requiredOutput } from '../modules/module.js'
import type { EarnDeploymentProfile } from './profile.js'

export type CreationDependencies = {
  /** Compiles the declared contract's creation bytes with its pinned deploy environment. */
  creationBytecode: (
    root: string,
    contract: string,
    environment: Readonly<Record<string, string | undefined>>,
  ) => Hex
}

const defaultDependencies: CreationDependencies = {
  creationBytecode: (root, contract, environment) => {
    assertFoundryProjectEnvironment(root)
    const bytecode = execFileSync('forge', ['inspect', contract, 'bytecode'], {
      cwd: root,
      encoding: 'utf8',
      env: foundryVerificationEnvironment(environment),
    }).trim()
    if (!/^0x(?:[0-9a-fA-F]{2})+$/.test(bytecode))
      throw new Error(`Forge returned invalid creation bytecode for ${contract}`)
    return bytecode as Hex
  },
}

/** Validates hosted creation evidence before it can become durable resume state or a deployment record. */
export async function assertStepCreation(
  options: {
    client: Pick<PublicClient, 'getTransactionReceipt' | 'getTransaction'>
    root: string
    environment: Readonly<Record<string, string | undefined>>
    outputs: Record<string, Address>
    profile: EarnDeploymentProfile
    step: FoundryStep
    transactions: readonly Hex[]
  },
  dependencies: Partial<CreationDependencies> = {},
) {
  const { client, outputs, profile, step, transactions } = options
  // Local scripts can batch transactions; only hosted records require canonical creation evidence.
  if (!isHostedDeploymentChain(profile.chainId)) return
  const factory = step.creationEvent?.(profile, outputs)
  const output = step.source?.output ?? factory?.output
  if (!output) {
    if (step.creates?.length) throw new Error(`Creation output is not declared for ${step.id}`)
    return
  }
  if (transactions.length !== 1)
    throw new Error(`Missing or ambiguous creation transaction for ${step.id}`)
  const transaction = transactions[0]!
  const address = requiredOutput(outputs, output)
  assertCreationReceipt({
    address,
    factory,
    receipt: await client.getTransactionReceipt({ hash: transaction }).catch(() => {
      // RPC failures do not disprove creation, and their messages may expose endpoint credentials.
      throw new Error(
        `Cannot validate creation receipt for ${transaction}; retry when the RPC receipt is available`,
      )
    }),
    transaction,
  })
  if (!factory) {
    if (!step.source) throw new Error(`Direct creation source is not declared for ${step.id}`)
    const creationBytecode = (
      dependencies.creationBytecode ?? defaultDependencies.creationBytecode
    )(foundryProjectRoot(options.root, step.project), step.source.contract, options.environment)
    const minedTransaction = await client.getTransaction({ hash: transaction }).catch(() => {
      throw new Error(
        `Cannot validate creation transaction for ${transaction}; retry when the RPC transaction is available`,
      )
    })
    assertDirectCreationTransaction({
      address,
      transaction,
      deployer: profile.deployer,
      creationBytecode,
      constructorArgs: step.source.constructorArgs(profile, outputs),
      minedTransaction,
    })
  }
}
