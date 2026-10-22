import { parseArgs } from 'node:util'

import { getAddress } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { createClient } from 'viem/tempo'

import { configuredTempoChain } from '../../chain/tempo.js'
import {
  loadDeploymentEnvironment,
  loadEarnProfile,
  profileRepositoryRoot,
  resolveProfilePath,
} from '../../core/bundle.js'
import { configuredRpcTransport, envPrivateKey } from '../../chain/runtime.js'
import { loadHostedProfileStack } from '../../core/profile-stack.js'
import {
  readAccessStatus,
  requireProtectedAccess,
  resolveAccessAddress,
  setAccessEligibility,
} from './membership.js'
import type { CapabilityCommand } from '../module.js'

const usage = 'Usage: pnpm earn access --earn-file <profile.json> <status|add|remove> <address>'

/**
 * `pnpm earn access`: reads, adds, or removes one member of a deployed profile's TIP-403
 * whitelist. Every target resolves through its virtual-address master; status is read-only, and a
 * change signs as the registered access administrator after the removal-safety checks.
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
  print(
    await setAccessEligibility({
      client: publicClient,
      deployment: stack,
      target: resolvedAddress,
      allowed: command === 'add',
      wallet,
    }),
  )
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
