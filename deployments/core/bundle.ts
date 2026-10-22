import { chmodSync, existsSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { basename, dirname, isAbsolute, join, resolve } from 'node:path'
import { isDeepStrictEqual, parseEnv } from 'node:util'
import type { Address } from 'viem'

import { privateKeyToAccount } from 'viem/accounts'

import { envPrivateKey } from '../chain/runtime.js'
import {
  parseFactoryRelease,
  resolveEarnFactoryRelease,
  sameFactoryRelease,
  type EarnFactoryRelease,
} from './releases.js'
import { address, object } from './parse.js'
import { parseEarnDeploymentProfile, type EarnDeploymentProfile } from './profile.js'
import { parseEarnDeploymentRecord, type EarnDeploymentRecord } from './record.js'

export type EarnProfileBundle = {
  path: string
  recordPath: string
  profile: EarnDeploymentProfile
  record: EarnDeploymentRecord
}

/** Loads one authored profile and enforces its canonical filename identity. */
export function loadEarnProfile(
  profilePath: string,
  options: { deployer?: Address; factories?: EarnFactoryRelease } = {},
) {
  const document = JSON.parse(readFileSync(profilePath, 'utf8')) as unknown
  const profile = parseEarnDeploymentProfile(document, options)
  if (basename(profilePath) !== 'profile.json' || basename(dirname(profilePath)) !== profile.id) {
    throw new Error(`Deployment profile ${profilePath} must be ${profile.id}/profile.json`)
  }
  return profile
}

/**
 * The repository that owns a profile: profiles live at `<root>/profiles/<id>/profile.json`, in Earn
 * or in a private deployments repository, and that root holds their ignored `.env.<id>`.
 */
export function profileRepositoryRoot(profilePath: string) {
  return dirname(dirname(dirname(resolve(profilePath))))
}

/** Resolves a profile argument against the directory the command was started from. */
export function resolveProfilePath(input: string) {
  return isAbsolute(input) ? input : resolve(process.env.INIT_CWD ?? process.cwd(), input)
}

/**
 * Loads only `.env.<profile-id>` beneath explicit injected values. Each `required` name must be set
 * by one of them, so a missing or incomplete dotenv fails here, naming the file, unless the caller's
 * environment (for example CI) already supplies the values.
 */
export function loadDeploymentEnvironment(
  root: string,
  profileId: string,
  injected: NodeJS.ProcessEnv = process.env,
  required: readonly string[] = [],
) {
  const path = resolve(root, `.env.${profileId}`)
  const exists = existsSync(path)
  const fileValues = exists ? parseEnv(readFileSync(path, 'utf8')) : {}
  const injectedValues = Object.fromEntries(
    Object.entries(injected).filter((entry): entry is [string, string] => entry[1] !== undefined),
  )
  const values = { ...fileValues, ...injectedValues }
  const missing = required.filter((name) => !values[name])
  if (missing.length > 0) {
    throw new Error(
      `${missing.join(', ')} ${missing.length === 1 ? 'is' : 'are'} required for profile ${profileId}: ` +
        (exists
          ? `set ${missing.length === 1 ? 'it' : 'them'} in ${path} or the environment`
          : `${path} does not exist; copy .env.example to it or export the values`),
    )
  }
  return values
}

/** Resolves the runtime deployment account without making it authored profile intent. */
function deploymentAccount(values: Readonly<Record<string, string | undefined>>) {
  return privateKeyToAccount(envPrivateKey(values, 'DEPLOYER_PRIVATE_KEY', { required: true }))
    .address
}

export function loadEarnProfileForEnvironment(
  profilePath: string,
  environment: Readonly<Record<string, string | undefined>>,
) {
  const preliminary = loadEarnProfile(profilePath)
  const recordPath = profileDeploymentPath(profilePath)
  const pendingPath = pendingDeploymentPath(profilePath)
  const identityPath = existsSync(recordPath)
    ? recordPath
    : existsSync(pendingPath)
      ? pendingPath
      : undefined
  const recorded = identityPath ? readDeploymentIdentity(identityPath) : undefined
  // A committed record keeps the release it pinned; anything unpublished uses the current one.
  if (
    identityPath === pendingPath &&
    !sameFactoryRelease(recorded!.factories, resolveEarnFactoryRelease(preliminary.chainId))
  ) {
    throw new Error(`Pending deployment ${pendingPath} does not use the current factory release`)
  }
  return loadEarnProfile(profilePath, {
    deployer: recorded?.deployer ?? deploymentAccount(environment),
    factories: recorded?.factories ?? resolveEarnFactoryRelease(preliminary.chainId),
  })
}

/** Loads the canonical authored/generated pair through one strict consumer boundary. */
export function loadEarnProfileBundle(profilePath: string): EarnProfileBundle {
  const recordPath = profileDeploymentPath(profilePath)
  const identity = readDeploymentIdentity(recordPath)
  const profile = loadEarnProfile(profilePath, {
    deployer: identity.deployer,
    factories: identity.factories,
  })
  return {
    path: profilePath,
    recordPath,
    profile,
    record: loadProfileDeploymentRecord(profilePath, profile),
  }
}

function readDeploymentIdentity(recordPath: string) {
  const value = object(JSON.parse(readFileSync(recordPath, 'utf8')), recordPath)
  return {
    deployer: address(value.deployer, `${recordPath}.deployer`),
    owner: address(value.owner, `${recordPath}.owner`),
    factories: parseFactoryRelease(value.factories, `${recordPath}.factories`),
  }
}

/** Resolves a role-named artifact beside an authored `profile.json`. */
function profileArtifactPath(profilePath: string, artifact: string) {
  if (basename(profilePath) !== 'profile.json') {
    throw new Error(`Deployment profile ${profilePath} must be named profile.json`)
  }
  return join(dirname(profilePath), `${artifact}.json`)
}

/** The generated, commit-ready deployment result lives beside its authored profile. */
export function profileDeploymentPath(profilePath: string) {
  return profileArtifactPath(profilePath, 'deployment')
}

/** Atomically publishes a complete validated record without an intermediate public cache. */
export function publishProfileDeploymentRecord(
  profilePath: string,
  profile: EarnDeploymentProfile,
  record: EarnDeploymentRecord,
) {
  const parsed = parseEarnDeploymentRecord(record, profile)
  const outputPath = profileDeploymentPath(profilePath)
  if (existsSync(outputPath) && sameDeploymentState(readJson(outputPath), parsed)) return outputPath
  const temporary = join(dirname(outputPath), `.${basename(outputPath)}.${process.pid}.tmp`)
  writeFileSync(temporary, `${JSON.stringify(parsed, null, 2)}\n`, { mode: 0o644 })
  chmodSync(temporary, 0o644)
  renameSync(temporary, outputPath)
  return outputPath
}

/** Reconciliation timestamps are not deployment state and must not dirty a clean checkout. */
function sameDeploymentState(existing: unknown, candidate: unknown) {
  try {
    const existingRecord = existing as Record<string, unknown>
    const candidateRecord = candidate as Record<string, unknown>
    const { generatedAt: _existingGeneratedAt, ...existingState } = existingRecord
    const { generatedAt: _candidateGeneratedAt, ...candidateState } = candidateRecord
    return isDeepStrictEqual(existingState, candidateState)
  } catch {
    return false
  }
}

/** The ignored, resumable deployment state lives beside the authored profile. */
export function pendingDeploymentPath(profilePath: string) {
  return profileArtifactPath(profilePath, 'deployment.pending')
}

export function loadProfileDeploymentRecord(
  profilePath: string,
  profile: EarnDeploymentProfile,
): EarnDeploymentRecord {
  const path = profileDeploymentPath(profilePath)
  if (!existsSync(path)) {
    throw new Error(
      `No generated deployment result at ${path}. Run pnpm earn deploy ${profilePath} first.`,
    )
  }
  return parseEarnDeploymentRecord(readJson(path), profile, path)
}

/** Deployment-only loader that may reconcile changed optional-component immutables. */
export function loadProfileDeploymentRecordForReconciliation(
  profilePath: string,
  profile: EarnDeploymentProfile,
) {
  const path = profileDeploymentPath(profilePath)
  if (!existsSync(path)) return undefined
  return parseEarnDeploymentRecord(readJson(path), profile, path, { allowPeripheryMismatch: true })
}

function readJson(path: string): unknown {
  try {
    return JSON.parse(readFileSync(path, 'utf8'))
  } catch {
    return undefined
  }
}
