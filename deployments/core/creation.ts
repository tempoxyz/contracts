import type { Address, Hex, PublicClient } from 'viem'

import { isHostedDeploymentChain } from '../chain/tempo.js'
import { assertCreationReceipt } from '../chain/creation.js'
import type { FoundryStep } from '../modules/module.js'
import { requiredOutput } from '../modules/module.js'
import type { EarnDeploymentProfile } from './profile.js'

/** Validates hosted creation evidence before it can become durable resume state or a deployment record. */
export async function assertStepCreation(options: {
  client: Pick<PublicClient, 'getTransactionReceipt'>
  outputs: Record<string, Address>
  profile: EarnDeploymentProfile
  step: FoundryStep
  transactions: readonly Hex[]
}) {
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
  assertCreationReceipt({
    address: requiredOutput(outputs, output),
    factory,
    receipt: await client.getTransactionReceipt({ hash: transaction }).catch(() => {
      // RPC failures do not disprove creation, and their messages may expose endpoint credentials.
      throw new Error(
        `Cannot validate creation receipt for ${transaction}; retry when the RPC receipt is available`,
      )
    }),
    transaction,
  })
}
