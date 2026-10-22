import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs'
import { basename, dirname, isAbsolute, relative, resolve } from 'node:path'

import type { Address } from 'viem'

import { address, object } from './parse.js'

import { deploymentActions, planEarnDeployment, type EarnDeploymentActionId } from './plan.js'
import { capabilityModules, deploymentStep } from '../modules/index.js'
import { pendingDeploymentPath } from './bundle.js'
import {
  componentDeploymentIntentHashes,
  deploymentIntentHash,
  type EarnDeploymentProfile,
} from './profile.js'
import {
  deploymentAddressComponents,
  deploymentAddressKeys,
  type DeploymentAddressKey,
} from './components.js'
import {
  parseCompletedAction,
  type CompletedDeploymentAction,
  type EarnDeploymentRecord,
} from './record.js'
import {
  parseFactoryRelease,
  parseFactoryRuntimeCodeHashes,
  sameFactoryRelease,
  type SharedFactoryRuntimeCodeHashes,
} from './releases.js'

/**
 * The deployment identity a profile's pending state is bound to. `bundle.ts` reads `deployer` and
 * `factories` back so a resumed deployment keeps them.
 */
function pendingHeader(profile: EarnDeploymentProfile) {
  return {
    version: 3 as const,
    profileId: profile.id,
    deployer: profile.deployer,
    owner: profile.owner,
    factories: profile.factories,
    deploymentIntentHash: deploymentIntentHash(profile),
  }
}

export type PendingDeployment = ReturnType<typeof pendingHeader> & {
  factoryRuntimeCodeHashes?: SharedFactoryRuntimeCodeHashes
  outputs: Record<string, Address>
  actions: Partial<Record<EarnDeploymentActionId, CompletedDeploymentAction>>
  latestOutputs?: Record<string, Address>
}

export function loadPendingDeployment(
  profilePath: string,
  profile: EarnDeploymentProfile,
): PendingDeployment {
  const path = pendingDeploymentPath(profilePath)
  const header = pendingHeader(profile)
  if (!existsSync(path)) return { ...header, outputs: {}, actions: {} }
  const pending = object(JSON.parse(readFileSync(path, 'utf8')), path)
  const matches = (() => {
    try {
      return (
        pending.version === header.version &&
        pending.profileId === header.profileId &&
        address(pending.deployer, 'deployer') === header.deployer &&
        address(pending.owner, 'owner') === header.owner &&
        sameFactoryRelease(parseFactoryRelease(pending.factories, 'factories'), header.factories) &&
        pending.deploymentIntentHash === header.deploymentIntentHash
      )
    } catch {
      return false
    }
  })()
  if (!matches) {
    throw new Error(
      `Pending deployment ${path} does not match this profile, deployer, factory release, or intent ` +
        'hash. Finish it with the Earn checkout that started it, or move it aside and start a fresh ' +
        'deployment with a new profile version.',
    )
  }

  const invalid = (field: string) => new Error(`Pending deployment ${path} has invalid ${field}`)
  const addresses = (field: string, label: string, allowed: (key: string) => boolean) => {
    const entries = pending[field] === undefined ? {} : object(pending[field], `${path}.${field}`)
    return Object.fromEntries(
      Object.entries(entries).map(([key, value]) => {
        if (!allowed(key)) throw invalid(`${label} ${key}`)
        try {
          return [key, address(value, key)]
        } catch {
          throw invalid(`${label} ${key}`)
        }
      }),
    ) as Record<string, Address>
  }
  const recordedAddress = (key: string) =>
    deploymentAddressKeys.includes(key as DeploymentAddressKey)
  const outputs = addresses(
    'outputs',
    'output',
    (key) =>
      recordedAddress(key) || capabilityModules.some((module) => module.metadataOutput?.(key)),
  )
  // Written by the Foundry step the deployment is executing; see `readActionOutputs`.
  const latestOutputs = addresses('latestOutputs', 'latest output', recordedAddress)
  const allowedActions = new Set<string>(planEarnDeployment(profile).map((action) => action.id))
  const actions: PendingDeployment['actions'] = {}
  for (const [key, value] of Object.entries(object(pending.actions, `${path}.actions`))) {
    if (!allowedActions.has(key)) throw invalid(`action ${key}`)
    actions[key as EarnDeploymentActionId] = parseCompletedAction(value, `${path}.actions.${key}`)
  }
  return {
    ...header,
    ...(pending.factoryRuntimeCodeHashes === undefined
      ? {}
      : {
          factoryRuntimeCodeHashes: parseFactoryRuntimeCodeHashes(
            pending.factoryRuntimeCodeHashes,
            `${path}.factoryRuntimeCodeHashes`,
          ),
        }),
    outputs,
    actions,
    ...(Object.keys(latestOutputs).length > 0 ? { latestOutputs } : {}),
  }
}

/** Writes pending state only when its identity is the profile's own, so it never moves between deployments. */
export function savePendingDeployment(
  profilePath: string,
  profile: EarnDeploymentProfile,
  pending: PendingDeployment,
) {
  const header = pendingHeader(profile)
  if (
    pending.version !== header.version ||
    pending.profileId !== header.profileId ||
    pending.deployer !== header.deployer ||
    pending.owner !== header.owner ||
    !sameFactoryRelease(pending.factories, header.factories) ||
    pending.deploymentIntentHash !== header.deploymentIntentHash
  ) {
    throw new Error('Pending deployment does not match this profile')
  }
  writeJsonAtomic(pendingDeploymentPath(profilePath), pending)
}

export function restorePendingDeployment(
  profilePath: string,
  profile: EarnDeploymentProfile,
  committed: Pick<
    EarnDeploymentRecord,
    'addresses' | 'actions' | 'componentDeploymentIntentHashes'
  >,
): PendingDeployment {
  let cached: PendingDeployment
  try {
    cached = loadPendingDeployment(profilePath, profile)
  } catch {
    cached = { ...pendingHeader(profile), outputs: {}, actions: {} }
  }
  const currentComponents = componentDeploymentIntentHashes(profile)
  const recordedComponents = committed.componentDeploymentIntentHashes
  const componentMatches = (id: EarnDeploymentActionId) =>
    deploymentStep(id).intent.every(
      (component) => recordedComponents[component] === currentComponents[component],
    )
  const committedDeploymentActions = Object.fromEntries(
    deploymentActions(profile).flatMap((action) =>
      committed.actions[action.id] && componentMatches(action.id)
        ? [[action.id, committed.actions[action.id]]]
        : [],
    ),
  ) as PendingDeployment['actions']
  const addressComponentMatches = (key: DeploymentAddressKey) => {
    const component = deploymentAddressComponents[key]
    return component !== undefined && recordedComponents[component] === currentComponents[component]
  }
  const committedAddresses = Object.fromEntries(
    Object.entries(committed.addresses).filter(([key]) =>
      addressComponentMatches(key as DeploymentAddressKey),
    ),
  )
  const pending: PendingDeployment = {
    ...pendingHeader(profile),
    outputs: { ...cached.outputs, ...committedAddresses },
    actions: { ...cached.actions, ...committedDeploymentActions },
  }
  savePendingDeployment(profilePath, profile, pending)
  return pending
}

export function removePendingDeployment(profilePath: string) {
  rmSync(pendingDeploymentPath(profilePath), { force: true })
}

/**
 * Where a Foundry step writes its `latestOutputs`. Forge runs from `root` and `foundry.toml` lets it
 * write only inside that checkout, so a profile outside `<root>/profiles`, such as one in a private
 * deployments repository, gets a staging copy of its pending state under `<root>/.earn/external`.
 */
export function foundryOutputPath(root: string, profilePath: string) {
  const pending = pendingDeploymentPath(profilePath)
  const fromProfiles = relative(resolve(root, 'profiles'), resolve(pending))
  if (!fromProfiles.startsWith('..') && !isAbsolute(fromProfiles)) return pending
  return resolve(
    root,
    '.earn',
    'external',
    basename(dirname(profilePath)),
    'deployment.pending.json',
  )
}

/** Copies pending state to the staging path before Forge writes `latestOutputs` into it. */
export function stageFoundryOutputs(root: string, profilePath: string) {
  const staged = foundryOutputPath(root, profilePath)
  const pending = pendingDeploymentPath(profilePath)
  if (staged === pending) return
  writeJsonAtomic(staged, JSON.parse(readFileSync(pending, 'utf8')))
}

/**
 * Moves the `latestOutputs` Forge wrote to a staging path back beside the profile, so the pending
 * state there always holds them, including after an interrupted run.
 */
export function syncFoundryOutputs(root: string, profilePath: string) {
  const staged = foundryOutputPath(root, profilePath)
  const pending = pendingDeploymentPath(profilePath)
  if (staged === pending || !existsSync(staged)) return
  const written = object(JSON.parse(readFileSync(staged, 'utf8')), staged)
  if (written.latestOutputs !== undefined) {
    const current = existsSync(pending)
      ? object(JSON.parse(readFileSync(pending, 'utf8')), pending)
      : written
    for (const field of ['version', 'profileId', 'deployer', 'deploymentIntentHash']) {
      if (current[field] !== written[field]) {
        throw new Error(
          `Staged Foundry outputs ${staged} belong to a different deployment than ${pending}; ` +
            'move the staged file aside and re-run.',
        )
      }
    }
    writeJsonAtomic(pending, { ...current, latestOutputs: written.latestOutputs })
  }
  rmSync(dirname(staged), { recursive: true })
}

export function completeAction(
  pending: PendingDeployment,
  id: EarnDeploymentActionId,
  verification: CompletedDeploymentAction['verification'],
  transactions: `0x${string}`[],
): PendingDeployment {
  const { latestOutputs: _latestOutputs, ...verified } = pending
  return {
    ...verified,
    actions: {
      ...pending.actions,
      [id]: { completedAt: new Date().toISOString(), verification, transactions },
    },
  }
}

/** Pending state may hold resume metadata, so it stays private to the operator. */
function writeJsonAtomic(path: string, value: unknown) {
  mkdirSync(dirname(path), { recursive: true })
  const temporary = `${path}.${process.pid}.tmp`
  writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 })
  renameSync(temporary, path)
}
