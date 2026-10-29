import { readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { getAddress } from 'viem'
import { zoneFactoryAddress, zoneMessengerAddress } from '@tempoxyz/contracts/tempo/zone'

export const root = dirname(dirname(dirname(fileURLToPath(import.meta.url))))
export const directory = resolve(root, 'localnet/.local')
/** Earn's Foundry project, where every fixture and lifecycle Forge step runs. */
export const earnRoot = resolve(root, 'earn')

export type RuntimeLock = {
  version: 1
  protocol: 'tip1091-v1'
  zoneInfoFields: 9
  l1Image: string
  zoneImage: string
  runtimeFixture: 'tip1091-runtime.json'
  runtimeFixtureSha256: string
  sourceCommit: string
  solcVersion: string
}

export const runtimeLock = parseRuntimeLock(
  JSON.parse(readFileSync(resolve(root, 'localnet/fixtures/runtime-lock.json'), 'utf8')),
)

export const address = {
  pathUsd: getAddress('0x20C0000000000000000000000000000000000000'),
  tip20Factory: getAddress('0x20Fc000000000000000000000000000000000000'),
  zoneFactory: getAddress(zoneFactoryAddress),
  zoneMessenger: getAddress(zoneMessengerAddress),
  zonePortalImplementation: getAddress('0x5AD1000000000000000000000000000000000000'),
  zoneVerifier: getAddress('0x5A56000000000000000000000000000000000000'),
}

/** The pinned image pair; replace both by editing the runtime lock. */
export const image = { l1: runtimeLock.l1Image, zone: runtimeLock.zoneImage }

export const history = {
  address: '0x0000f90827f1c53a10cb7a02335b175320002935',
  code: '0x3373fffffffffffffffffffffffffffffffffffffffe14604657602036036042575f35600143038111604257611fff81430311604257611fff9006545f5260205ff35b5f5ffd5b5f35611fff60014303065500',
}

function parseRuntimeLock(value: unknown): RuntimeLock {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('runtime lock must be an object')
  }
  const lock = value as Record<string, unknown>
  const keys = [
    'version',
    'protocol',
    'zoneInfoFields',
    'l1Image',
    'zoneImage',
    'runtimeFixture',
    'runtimeFixtureSha256',
    'sourceCommit',
    'solcVersion',
  ]
  if (Object.keys(lock).length !== keys.length || keys.some((key) => !(key in lock))) {
    throw new Error('runtime lock has an unsupported shape')
  }
  if (
    lock.version !== 1 ||
    lock.protocol !== 'tip1091-v1' ||
    lock.zoneInfoFields !== 9 ||
    lock.runtimeFixture !== 'tip1091-runtime.json'
  ) {
    throw new Error('runtime lock has an unsupported protocol version')
  }
  if (
    typeof lock.l1Image !== 'string' ||
    typeof lock.zoneImage !== 'string' ||
    !lock.l1Image.includes('@sha256:') ||
    !lock.zoneImage.includes('@sha256:')
  ) {
    throw new Error('runtime lock images must use immutable sha256 digests')
  }
  if (
    typeof lock.sourceCommit !== 'string' ||
    !/^[0-9a-f]{40}$/.test(lock.sourceCommit) ||
    typeof lock.runtimeFixtureSha256 !== 'string' ||
    !/^[0-9a-f]{64}$/.test(lock.runtimeFixtureSha256) ||
    typeof lock.solcVersion !== 'string' ||
    !/^\d+\.\d+\.\d+$/.test(lock.solcVersion)
  ) {
    throw new Error('runtime lock provenance is invalid')
  }
  return lock as RuntimeLock
}
