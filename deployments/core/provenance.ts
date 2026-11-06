import { spawnSync } from 'node:child_process'

import { keccak256, type PublicClient } from 'viem'

import { profileFactoryDeploymentId, type EarnDeploymentProfile } from './profile.js'
import {
  runtimeCodeAddressKeysFor,
  type DeploymentAddresses,
  type DeploymentSource,
  type EarnDeploymentRecord,
} from './record.js'
import { runtimeCodeHash } from './releases.js'
import { tempoVerifierUrl } from './verify.js'
import { deploymentSteps } from '../modules/index.js'
import {
  assertFoundryProjectEnvironment,
  foundryVerificationEnvironment,
} from '../chain/foundry.js'

/**
 * Record provenance: the runtime code, receipts, and checkout a deployment record was built from.
 * Source verification against the Tempo verifier lives in `verify.ts`.
 */

export async function runtimeCodeHashes(
  client: Pick<PublicClient, 'getCode'>,
  addresses: DeploymentAddresses,
) {
  const keys = runtimeCodeAddressKeysFor(addresses)
  const hashes = await Promise.all(
    keys.map((key) => runtimeCodeHash(client, addresses[key]!, `addresses.${key}`)),
  )
  return Object.fromEntries(
    keys.map((key, index) => [key, hashes[index]]),
  ) as EarnDeploymentRecord['runtimeCodeHashes']
}

/**
 * The block of the earliest receipt among the actions' transactions, every one of which must have
 * succeeded; `undefined` when the actions carry none.
 */
export async function earliestDeploymentBlock(
  client: Pick<PublicClient, 'getTransactionReceipt'>,
  actions: EarnDeploymentRecord['actions'],
) {
  const transactions = [...new Set(Object.values(actions).flatMap((action) => action.transactions))]
  const receipts = await Promise.all(
    transactions.map((hash) => client.getTransactionReceipt({ hash })),
  )
  const reverted = receipts.find((receipt) => receipt.status !== 'success')
  if (reverted) throw new Error(`Deployment transaction ${reverted.transactionHash} reverted`)
  return receipts.reduce<bigint | undefined>(
    (minimum, receipt) =>
      minimum === undefined || receipt.blockNumber < minimum ? receipt.blockNumber : minimum,
    undefined,
  )
}

export async function verifyDeploymentProvenance(
  client: Pick<PublicClient, 'getCode' | 'getTransactionReceipt'>,
  record: EarnDeploymentRecord,
) {
  const hashes = await runtimeCodeHashes(client, record.addresses)
  for (const key of runtimeCodeAddressKeysFor(record.addresses)) {
    const expected = record.runtimeCodeHashes[key]
    if (!expected || hashes[key]?.toLowerCase() !== expected.toLowerCase()) {
      throw new Error(`Runtime bytecode hash changed for addresses.${key}`)
    }
  }
  const earliest = await earliestDeploymentBlock(client, record.actions)
  if (earliest !== undefined && earliest.toString() !== record.deploymentBlock) {
    throw new Error(
      `deploymentBlock is ${record.deploymentBlock}, but the earliest recorded receipt is ${earliest}`,
    )
  }
  const hasCoreCreation = deploymentSteps.some(
    (step) =>
      step.execution === 'foundry' &&
      step.intent.includes('core') &&
      (record.actions[step.id]?.transactions.length ?? 0) > 0,
  )
  if (!hasCoreCreation) {
    // A later configuration receipt cannot establish when an adopted vault first accepted claims.
    const block = BigInt(record.deploymentBlock)
    const address = record.addresses.earnVault
    if (!address) throw new Error('Adopted record has no EarnVault creation bound')
    const before =
      block > 0n ? await client.getCode({ address, blockNumber: block - 1n }) : undefined
    if (before && before !== '0x')
      throw new Error(
        'deploymentBlock requires archive proof that the claim scan starts before EarnVault creation',
      )
    if (earliest === undefined) {
      // With no receipts at all, the claimed block itself must prove creation, not just a conservative bound.
      const at = await client.getCode({ address, blockNumber: block })
      if (!at || at === '0x' || keccak256(at) !== record.runtimeCodeHashes.earnVault)
        throw new Error(
          'Receipt-free deploymentBlock requires archive proof of EarnVault creation at that block',
        )
    }
  }
}

/** The TIP-20 factory and implementations an EarnFactory deploys every stack with. */
export function captureDeploymentSource(options: {
  profile: EarnDeploymentProfile
  root: string
  contractVerification: DeploymentSource['contractVerification']
  contracts?: DeploymentSource['contracts']
}): DeploymentSource {
  const commit = command(options.root, 'git', ['rev-parse', 'HEAD'])
  const dirty = command(options.root, 'git', ['status', '--porcelain', '--untracked-files=no'])
  const foundryVersion = command(options.root, 'forge', ['--version'])
  return {
    factoryDeploymentId: profileFactoryDeploymentId(options.profile),
    commit: commit && /^[0-9a-fA-F]{40}$/.test(commit) ? (`0x${commit}` as const) : null,
    treeDirty: dirty === undefined ? null : dirty.length > 0,
    foundryVersion: foundryVersion ?? null,
    contractVerification: options.contractVerification,
    verifierUrl: options.contractVerification === 'verified' ? tempoVerifierUrl : null,
    contracts: options.contracts ?? {},
  }
}

function command(root: string, executable: string, arguments_: string[]) {
  if (executable === 'forge') assertFoundryProjectEnvironment(root)
  const result = spawnSync(executable, arguments_, {
    cwd: root,
    encoding: 'utf8',
    env: foundryVerificationEnvironment(process.env),
  })
  if (result.error || result.status !== 0) return undefined
  return result.stdout.trim()
}
