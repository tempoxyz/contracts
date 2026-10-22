import { Devnet } from 'localnet'
import type { E2eContext } from './context.js'
import { environmentDefinitions } from './environments.js'
import { runOnStack } from './local.js'
import type { SourceState } from './results.js'

/**
 * Runs the cases against a fresh default ERC-4626 stack that localnet deploys onto an existing L1
 * and Zone; validation and context are the local run's. The workflow injects the topology and
 * funded signers; nothing falls back to hosted defaults.
 */
export async function runDevnet<Result>(
  source: SourceState,
  execute: (context: E2eContext, manifest: { sha256: string; source: string }) => Promise<Result>,
) {
  const values = process.env
  const configuration = Devnet.configuration(values)
  return await Devnet.run({
    ...configuration,
    privateKeys: {
      ...configuration.privateKeys,
      user: Devnet.privateKey(values, 'END_USER_PRIVATE_KEY'),
      outsider: Devnet.privateKey(values, 'INELIGIBLE_USER_PRIVATE_KEY'),
      accessAdministrator: Devnet.privateKey(values, 'EARN_ACCESS_ADMIN_PRIVATE_KEY'),
    },
    ready: (state) => runOnStack(state, source, undefined, execute, environmentDefinitions.devnet),
  })
}
