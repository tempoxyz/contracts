import { execFileSync } from 'node:child_process'

/** A deployment revision is valid evidence only when its checkout contains no unpublished input. */
export function cleanSourceRevision(root: string) {
  const options = { cwd: root, encoding: 'utf8' as const }
  const status = execFileSync('git', ['status', '--porcelain', '--untracked-files=all'], options)
  if (status.trim())
    throw new Error(
      'Devnet deployment requires a clean source checkout; commit or remove unpublished changes first',
    )
  return execFileSync('git', ['rev-parse', '--verify', 'HEAD'], options).trim()
}

/** Serializes endpoint identity, not executable URLs: paths and queries can contain arbitrary credentials. */
export function stackManifest<
  const stack extends { network: { rpcUrl: string; zone?: { rpcUrl: string } } },
>(stack: stack) {
  return {
    ...stack,
    network: {
      ...stack.network,
      rpcUrl: endpointOrigin(stack.network.rpcUrl),
      ...(stack.network.zone
        ? { zone: { ...stack.network.zone, rpcUrl: endpointOrigin(stack.network.zone.rpcUrl) } }
        : {}),
    },
  }
}

function endpointOrigin(value: string) {
  const url = new URL(value)
  if (url.protocol !== 'http:' && url.protocol !== 'https:')
    throw new Error('RPC provenance requires an HTTP(S) endpoint')
  return url.origin
}
