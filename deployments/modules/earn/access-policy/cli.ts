import { existsSync, readdirSync, readFileSync, realpathSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { parseArgs } from 'node:util'

import { getAddress, isAddress, type Address, type PublicClient } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { createClient } from 'viem/tempo'

import { configuredTempoChain } from '../../../chain/tempo.js'
import {
  loadDeploymentEnvironment,
  loadEarnProfile,
  loadEarnProfileBundle,
  loadEarnProfileForRead,
  loadReviewedDeploymentIdentity,
  pendingDeploymentPath,
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
  const siblings =
    command === 'remove'
      ? await policySiblingStacks(path, stack, bundle.record.target.genesisHash, publicClient)
      : []
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
 * Every other deployed stack beside `profilePath` (each `<id>/profile.json` in its parent
 * directory, symlinked or not) on the same chain and genesis that attaches the same TIP-403 policy,
 * loaded live. Sharing is decided from each neighbour's verified authored/generated pair, so a
 * neighbour whose profile no longer matches its record, or that fails to load, stops the removal
 * and is named. A neighbour with only an unpublished deployment stops it when that deployment,
 * bound to its authored profile through the pending intent hash, targets this chain and policy, or
 * when that binding fails: its contracts may already be bound to the policy. A record naming
 * another genesis excludes a neighbour only when its EarnShare has no code on this chain. Each
 * neighbour runs with its own `.env.<id>`, which alone supplies its reviewed identity and, when it
 * names any, its RPC settings.
 */
export async function policySiblingStacks(
  profilePath: string,
  stack: EarnStack,
  genesisHash: string,
  client?: Pick<PublicClient, 'getCode'>,
) {
  if (stack.access.kind !== 'tip403-whitelist') return []
  const root = profileRepositoryRoot(profilePath)
  const directory = dirname(dirname(profilePath))
  const policyId = BigInt(stack.access.transferPolicyId)
  const siblings: EarnStack[] = []
  // Entries resolve through symlinks; aliases of a stack, including the selected one, count once.
  const seen = new Set([realpathSync(dirname(profilePath))])
  for (const name of readdirSync(directory).sort()) {
    const entry = join(directory, name)
    if (!existsSync(join(entry, 'profile.json'))) continue
    const real = realpathSync(entry)
    if (seen.has(real)) continue
    seen.add(real)
    const path = join(real, 'profile.json')
    const recorded = existsSync(profileDeploymentPath(path))
    if (!recorded && !existsSync(pendingDeploymentPath(path))) continue
    const fail = (reason: unknown): never => {
      const detail = redactUrls(reason instanceof Error ? reason.message : String(reason))
      throw new Error(`Cannot check removal safety against profile ${name}: ${detail}`, {
        cause: reason,
      })
    }
    try {
      const authored = loadEarnProfile(path)
      if (authored.id === stack.id) continue
      if (!recorded) {
        // Bind the authored profile to its pending intent first, so an edited profile cannot hide it.
        const pending = loadEarnProfileForRead(path)
        if (pending.chainId === stack.network.chainId && transferPolicyId(pending) === policyId) {
          fail(`it has an unpublished deployment on policy ${policyId}; publish its record first`)
        }
        continue
      }
      // Only a record that may target this chain can share the policy; others need no strict load.
      const target = recordTarget(path, authored.chainId, stack.network.chainId, genesisHash)
      if (target.kind === 'other-chain') continue
      if (target.kind === 'other-genesis') {
        // A wrong genesis must not hide a live stack: skip only when its EarnShare is not here.
        const code = client && (await client.getCode({ address: target.earnShare }))
        if (client && (!code || code === '0x')) continue
        fail(
          `its record names genesis ${target.genesisHash}, but its EarnShare may be live on this chain`,
        )
      }
      const values = siblingEnvironment(root, authored.id)
      const identityPath = values.EARN_TRUSTED_DEPLOYMENT_IDENTITY?.trim()
      const identity = identityPath
        ? loadReviewedDeploymentIdentity(resolveProfilePath(identityPath))
        : undefined
      const { profile, record } = loadEarnProfileBundle(path, identity)
      if (record.target.chainId !== stack.network.chainId) continue
      if (transferPolicyId(profile) !== policyId) continue
      siblings.push((await loadHostedProfileStack(path, values, identity)).stack)
    } catch (error) {
      if (error instanceof Error && error.message.startsWith('Cannot check removal safety')) {
        throw error
      }
      fail(error)
    }
  }
  return siblings
}

/**
 * Classifies a generated record's target before the strict load, so a neighbour on another chain
 * never blocks a removal. Only a well-formed target that agrees with its authored chain is trusted
 * to differ; anything malformed or inconsistent counts as possibly the same, so the strict load
 * rejects it.
 */
function recordTarget(
  profilePath: string,
  authoredChainId: number,
  chainId: number,
  genesisHash: string,
):
  | { kind: 'possibly-same' }
  | { kind: 'other-chain' }
  | { kind: 'other-genesis'; genesisHash: string; earnShare: Address } {
  try {
    const record = JSON.parse(readFileSync(profileDeploymentPath(profilePath), 'utf8')) as {
      target?: { chainId?: unknown; genesisHash?: unknown }
      addresses?: { earnShare?: unknown }
    }
    const target = record.target
    if (typeof target?.chainId !== 'number' || target.chainId !== authoredChainId) {
      return { kind: 'possibly-same' }
    }
    if (typeof target.genesisHash !== 'string' || !/^0x[0-9a-fA-F]{64}$/.test(target.genesisHash)) {
      return { kind: 'possibly-same' }
    }
    if (target.chainId !== chainId) return { kind: 'other-chain' }
    if (target.genesisHash.toLowerCase() === genesisHash.toLowerCase()) {
      return { kind: 'possibly-same' }
    }
    const earnShare = record.addresses?.earnShare
    if (typeof earnShare !== 'string' || !isAddress(earnShare)) return { kind: 'possibly-same' }
    return {
      kind: 'other-genesis',
      genesisHash: target.genesisHash,
      earnShare: getAddress(earnShare),
    }
  } catch {
    return { kind: 'possibly-same' }
  }
}

/** Keeps only each URL's origin, so RPC paths and query tokens never reach the terminal. */
export function redactUrls(message: string) {
  // Take the whole non-space token, since quotes, brackets and other punctuation are valid in
  // paths and credentials, and keep only trailing punctuation outside the redacted URL.
  return message.replace(/https?:\/\/\S+/g, (token) => {
    // Scan back from the end: linear, unlike an unanchored trailing-run regex.
    let end = token.length
    while (end > 0 && `).,;:!?'"<>`.includes(token[end - 1]!)) end--
    const trailing = token.slice(end)
    const candidate = token.slice(0, end)
    try {
      const url = new URL(candidate)
      const kept = candidate === url.origin || candidate === `${url.origin}/`
      return (kept ? url.origin : `${url.origin}/[redacted]`) + trailing
    } catch {
      return '[redacted URL]' + trailing
    }
  })
}

const rpcKeys = ['TEMPO_RPC_URL', 'TEMPO_RPC_USERNAME', 'TEMPO_RPC_PASSWORD'] as const

/**
 * A neighbour's runtime values: its own `.env.<id>` wins over the shell. Its reviewed identity
 * comes only from that file, and RPC settings move as a group: all from the file when it names any
 * of them, even blank, else all from the shell, so credentials never reach another endpoint. File
 * credentials without a file URL are refused rather than sent to the public fallback.
 */
export function siblingEnvironment(root: string, profileId: string) {
  const own = loadDeploymentEnvironment(root, profileId, {})
  const shell = loadDeploymentEnvironment(root, profileId, process.env)
  const values: Record<string, string | undefined> = {
    ...shell,
    ...own,
    EARN_TRUSTED_DEPLOYMENT_IDENTITY: own.EARN_TRUSTED_DEPLOYMENT_IDENTITY,
  }
  const fromFile = rpcKeys.some((key) => key in own)
  if (
    fromFile &&
    !own.TEMPO_RPC_URL?.trim() &&
    (own.TEMPO_RPC_USERNAME || own.TEMPO_RPC_PASSWORD)
  ) {
    // Without its own URL the hosted public endpoint would receive these private credentials.
    throw new Error(
      `.env.${profileId} sets TEMPO_RPC credentials without TEMPO_RPC_URL; set the URL there too`,
    )
  }
  for (const key of rpcKeys) values[key] = fromFile ? own[key] : shell[key]
  return values
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
