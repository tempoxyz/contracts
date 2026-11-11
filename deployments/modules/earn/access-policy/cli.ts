import { existsSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { parseArgs } from 'node:util'

import { getAddress } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { createClient } from 'viem/tempo'

import { configuredTempoChain } from '../../../chain/tempo.js'
import {
  loadDeploymentEnvironment,
  loadEarnProfile,
  profileDeploymentPath,
  profileRepositoryRoot,
  resolveProfilePath,
} from '../../../core/bundle.js'
import { configuredRpcTransport, envPrivateKey } from '../../../chain/runtime.js'
import { loadHostedProfileStack } from '../../../core/profile-stack.js'
import {
  readAccessStatus,
  requireProtectedAccess,
  resolveAccessAddress,
  setAccessEligibility,
} from './membership.js'
import type { EarnStack } from '../../../core/stack.js'
import type { CapabilityCommand } from '../../../../deployments/modules/module.js'
import { transferPolicyId } from './profile.js'

const usage = 'Usage: pnpm earn access --earn-file <profile.json> <status|add|remove> <address>'

/**
 * `pnpm earn access`: reads, adds, or removes one member of a deployed profile's TIP-403
 * whitelist. Every target resolves through its virtual-address master; status is read-only, and a
 * change signs as the registered access administrator after the removal-safety checks, which cover
 * every deployed profile in the same repository that attaches the same policy.
 */
export const accessCommand: CapabilityCommand = { name: 'access', usage, run: access }

async function access(argv: readonly string[], output: Pick<Console, 'log' | 'warn'>) {
  const { values: flags, positionals } = parseArgs({
    // pnpm forwards a bare `--`, which `parseArgs` would treat as the end of options.
    args: argv.filter((argument) => argument !== '--'),
    options: { 'earn-file': { type: 'string' } },
    allowPositionals: true,
  })
  const profilePath = flags['earn-file']
  if (profilePath === '') throw new Error('--earn-file requires a value')
  if (!profilePath) throw new Error(`--earn-file <profile.json> is required\n${usage}`)
  const [command, rawTarget] = positionals
  if (!isAccessCommand(command) || !rawTarget) throw new Error(usage)
  const path = resolveProfilePath(profilePath)
  const values = loadDeploymentEnvironment(
    profileRepositoryRoot(path),
    loadEarnProfile(path).id,
    process.env,
  )
  const { bundle, stack, tempo } = await loadHostedProfileStack(path, values)
  const target = getAddress(rawTarget)
  const transport = configuredRpcTransport({ url: stack.network.rpcUrl, headers: tempo.headers })
  const publicClient = createClient({ chain: configuredTempoChain(stack), transport })
  const resolvedAddress = await resolveAccessAddress(publicClient, target)
  const print = (value: Record<string, unknown>) =>
    output.log(JSON.stringify({ address: target, resolvedAddress, ...value }, null, 2))

  if (stack.access.kind === 'open') {
    if (command !== 'status') throw new Error('The current deployment has open access')
    print({ eligible: true })
    return
  }
  if (command === 'status') {
    print(await readAccessStatus(publicClient, stack, resolvedAddress))
    return
  }

  const { accessAdministrator } = requireProtectedAccess(stack)
  const administrator = accessAdministratorAccount(values, bundle.profile.id, output)
  if (getAddress(administrator.address) !== getAddress(accessAdministrator)) {
    throw new Error('Configured access signer does not match the registered access administrator')
  }
  const wallet = createClient({
    account: administrator,
    chain: configuredTempoChain(stack),
    transport,
  })
  const siblings = command === 'remove' ? await policySiblingStacks(path, stack) : []
  print(
    await setAccessEligibility({
      client: publicClient,
      deployment: stack,
      target: resolvedAddress,
      allowed: command === 'add',
      wallet,
      siblings,
    }),
  )
}

/**
 * Every other deployed profile beside `profilePath` (the other `<id>/profile.json` entries in its
 * parent directory) on the same chain that attaches the same TIP-403 policy, loaded live with its
 * own `.env.<id>`. A sibling's reviewed identity comes only from its own `.env.<id>`, never from
 * the shell, which names the selected profile's. A profile without a generated record has nothing
 * deployed to protect; any other load failure stops the removal rather than skipping it.
 */
async function policySiblingStacks(profilePath: string, stack: EarnStack) {
  if (stack.access.kind !== 'tip403-whitelist') return []
  const root = profileRepositoryRoot(profilePath)
  const profilesDirectory = dirname(dirname(profilePath))
  const policyId = BigInt(stack.access.transferPolicyId)
  const siblings: EarnStack[] = []
  for (const entry of readdirSync(profilesDirectory, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue
    const path = join(profilesDirectory, entry.name, 'profile.json')
    if (path === profilePath || !existsSync(path) || !existsSync(profileDeploymentPath(path))) {
      continue
    }
    const profile = loadEarnProfile(path)
    if (profile.id === stack.id || profile.chainId !== stack.network.chainId) continue
    if (transferPolicyId(profile) !== policyId) continue
    try {
      const values = loadDeploymentEnvironment(root, profile.id, process.env)
      const own = loadDeploymentEnvironment(root, profile.id, {})
      const siblingValues = {
        ...values,
        EARN_TRUSTED_DEPLOYMENT_IDENTITY: own.EARN_TRUSTED_DEPLOYMENT_IDENTITY,
      }
      siblings.push((await loadHostedProfileStack(path, siblingValues)).stack)
    } catch (error) {
      throw new Error(
        `Cannot check removal safety for ${profile.id}, which shares policy ${policyId}`,
        { cause: error },
      )
    }
  }
  return siblings
}

/**
 * The access administrator key from the profile's runtime config. Like hosted E2E, an unset
 * `EARN_ACCESS_ADMIN_PRIVATE_KEY` falls back to `DEPLOYER_PRIVATE_KEY`, announced on stderr so the
 * JSON result stays parseable; the caller still checks the signer against the registered address.
 */
function accessAdministratorAccount(
  values: Readonly<Record<string, string | undefined>>,
  profileId: string,
  output: Pick<Console, 'warn'>,
) {
  const administrator = envPrivateKey(values, 'EARN_ACCESS_ADMIN_PRIVATE_KEY')
  if (administrator) return privateKeyToAccount(administrator)
  const deployer = envPrivateKey(values, 'DEPLOYER_PRIVATE_KEY')
  if (!deployer) {
    throw new Error(
      `EARN_ACCESS_ADMIN_PRIVATE_KEY or DEPLOYER_PRIVATE_KEY is required in .env.${profileId} or the environment for access changes`,
    )
  }
  output.warn(
    'EARN_ACCESS_ADMIN_PRIVATE_KEY is unset; the access administrator signs with DEPLOYER_PRIVATE_KEY',
  )
  return privateKeyToAccount(deployer)
}

function isAccessCommand(value: string | undefined): value is 'status' | 'add' | 'remove' {
  return value === 'status' || value === 'add' || value === 'remove'
}
