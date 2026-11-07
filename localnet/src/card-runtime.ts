import { execFileSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { isDeepStrictEqual } from 'node:util'
import type { Hex } from 'viem'

import * as Config from './config.js'

const provenance = JSON.parse(
  readFileSync(resolve(Config.root, 'localnet/fixtures/card-runtime-provenance.json'), 'utf8'),
) as {
  evidence: { images: Record<'l1' | 'zone', { source: string; revision: string }> }
  runtime: Config.RuntimeLock
}

/** Checks the observed immutable image and its recorded build labels, not a signed build attestation. */
export function assertImageIdentity(role: 'l1' | 'zone', observed: ImageIdentity) {
  const expected = provenance.evidence.images[role]
  if (
    !isDeepStrictEqual(provenance.runtime, Config.runtimeLock) ||
    !observed.RepoDigests?.includes(Config.image[role]) ||
    observed.Config?.Labels?.['org.opencontainers.image.source'] !== expected.source ||
    observed.Config?.Labels?.['org.opencontainers.image.revision'] !== expected.revision
  )
    throw new Error(`Unreviewed ${role} image identity; update the runtime compatibility evidence`)
}

export type ImageIdentity = {
  RepoDigests?: string[]
  Config?: { Labels?: Record<string, string> | null }
}

/** Checks Docker's identity after the requested digest has been pulled. */
export function checkImageIdentity(role: 'l1' | 'zone') {
  const observed = JSON.parse(
    execFileSync('docker', ['image', 'inspect', Config.image[role], '--format', '{{json .}}'], {
      encoding: 'utf8',
    }),
  ) as ImageIdentity
  assertImageIdentity(role, observed)
}

/** Refuses a running L1 whose canonical runtime differs from the locked fixture. */
export function assertRuntimeCode(name: string, observed: Hex | undefined, expected: Hex) {
  if (!observed || observed.toLowerCase() !== expected.toLowerCase())
    throw new Error(`${name} deployed bytecode differs from the locked runtime`)
}

/** Removes only the reviewed solc 0.8.35 IPFS trailer; executable differences always fail. */
export function executable(code: string) {
  if (!/^0x(?:[0-9a-f]{2})+$/.test(code)) throw new Error('Invalid runtime bytecode')
  // Both builds use the same compiler and CBOR shape; only the source-path-dependent IPFS hash varies.
  const metadata = /a2646970667358221220[0-9a-f]{64}64736f6c63430008230033$/
  if (!metadata.test(code)) throw new Error('Unreviewed compiler metadata')
  return code.replace(metadata, '')
}
