import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { isDeepStrictEqual } from 'node:util'
import { getContainerRuntimeClient, ImageName } from 'testcontainers'
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
    !observed.RepoDigests?.includes(repositoryDigest(Config.image[role])) ||
    observed.Config?.Labels?.['org.opencontainers.image.source'] !== expected.source ||
    observed.Config?.Labels?.['org.opencontainers.image.revision'] !== expected.revision
  )
    throw new Error(`Unreviewed ${role} image identity; update the runtime compatibility evidence`)
}

export type ImageIdentity = {
  RepoDigests?: string[]
  Config?: { Labels?: Record<string, string> | null }
}

/** Checks the running container's image on the same daemon selected by Testcontainers. */
export async function checkImageIdentity(role: 'l1' | 'zone', containerId: string) {
  const runtime = await getContainerRuntimeClient()
  const container = await runtime.container.inspect(runtime.container.getById(containerId))
  const observed = await runtime.image.inspect(ImageName.fromString(container.Image))
  assertImageIdentity(role, observed)
}

/** Docker reports repository digests without the optional tag, while preserving registry ports. */
export function repositoryDigest(reference: string) {
  return reference.replace(/:[^/:@]+@/, '@')
}

/** Refuses missing or changed canonical runtime bytes, before overrides and after startup. */
export function assertRuntimeCode(name: string, observed: string | undefined, expected: Hex) {
  if (!observed || observed.toLowerCase() !== expected.toLowerCase())
    throw new Error(`${name} bytecode differs from the locked runtime`)
}

/** Removes only the reviewed solc 0.8.35 IPFS trailer; executable differences always fail. */
export function executable(code: string) {
  if (!/^0x(?:[0-9a-f]{2})+$/.test(code)) throw new Error('Invalid runtime bytecode')
  // Both builds use the same compiler and CBOR shape; only the source-path-dependent IPFS hash varies.
  const metadata = /a2646970667358221220[0-9a-f]{64}64736f6c63430008230033$/
  if (!metadata.test(code)) throw new Error('Unreviewed compiler metadata')
  return code.replace(metadata, '')
}
