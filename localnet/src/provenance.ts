import { execFileSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import {
  accessSync,
  constants,
  existsSync,
  lstatSync,
  readFileSync,
  readdirSync,
  realpathSync,
} from 'node:fs'
import { resolve } from 'node:path'
import { isDeepStrictEqual } from 'node:util'

import { dependencyEnvironment } from './foundry.js'

/** Checks the repository and installed Solidity sources, not the authenticity of local build tools. */
export function cleanSourceRevision(root: string) {
  const revision = cleanCheckoutRevision(root)
  for (const project of ['earn', 'zone-router']) assertDependencies(root, project)
  return revision
}

/** Installs missing build inputs without replacing edited libraries, then captures them before signer resolution. */
export function prepareBuildProvenance(root: string) {
  cleanCheckoutRevision(root)
  // The installer can replace wrong-revision libraries; validate every present checkout before it runs.
  for (const project of ['earn', 'zone-router']) assertDependencies(root, project, true)
  execFileSync(resolve(root, 'scripts/solidity-deps.sh'), ['earn', 'zone-router'], {
    cwd: root,
    env: dependencyEnvironment(process.env),
    stdio: 'inherit',
  })
  return captureBuildProvenance(root)
}

function cleanCheckoutRevision(root: string) {
  const options = { cwd: root, encoding: 'utf8' as const }
  const status = execFileSync('git', ['status', '--porcelain', '--untracked-files=all'], options)
  if (status.trim())
    throw new Error(
      'Devnet deployment requires a clean source checkout; commit or remove unpublished changes first',
    )
  return execFileSync('git', ['rev-parse', '--verify', 'HEAD'], options).trim()
}

/** Captures source evidence and the installed solar bytes without treating a local binary as authenticated. */
export function captureBuildProvenance(root: string) {
  const sourceRevision = cleanSourceRevision(root)
  const requestedSourceRevision = readFileSync(resolve(root, 'earn/solar.lock'), 'utf8').trim()
  if (!/^[0-9a-f]{40}$/.test(requestedSourceRevision))
    throw new Error('Invalid solar source revision in earn/solar.lock')
  const path = `.solar/${requestedSourceRevision}/bin/solar`
  const binary = resolve(root, path)
  const sha256 = (() => {
    try {
      accessSync(binary, constants.X_OK)
      const digest = createHash('sha256').update(readFileSync(binary)).digest('hex')
      const receipt = JSON.parse(
        readFileSync(
          resolve(root, `.solar/${requestedSourceRevision}/install-receipt.json`),
          'utf8',
        ),
      ) as unknown
      if (
        !isDeepStrictEqual(receipt, {
          schemaVersion: 1,
          sourceRevision: requestedSourceRevision,
          sha256: digest,
        })
      )
        throw new Error('Compiler differs from its pinned installation receipt')
      return digest
    } catch (cause) {
      throw new Error(
        'Devnet solar compiler requires a matching install receipt; run pnpm deps for a fresh pinned rebuild before deploying',
        {
          cause,
        },
      )
    }
  })()
  return {
    schemaVersion: 1,
    sourceRevision,
    solar: {
      path,
      requestedSourceRevision,
      sha256,
      // The installer receipt detects replacement, but is not a remote signature or independent build attestation.
      authenticated: false,
    },
  }
}

/** Refuses a success record if the checked source or observed compiler bytes changed during deployment. */
export function assertBuildProvenanceUnchanged(
  root: string,
  before: ReturnType<typeof captureBuildProvenance>,
) {
  if (!isDeepStrictEqual(before, captureBuildProvenance(root)))
    throw new Error('Devnet build inputs changed during deployment; refusing provenance output')
}

function assertDependencies(root: string, project: string, allowMissing = false) {
  const directory = resolve(root, project)
  const lock = JSON.parse(readFileSync(resolve(directory, 'foundry.lock'), 'utf8')) as Record<
    string,
    { rev?: string; tag?: { rev?: string } }
  >
  const paths = Object.keys(lock)
  if (paths.length === 0 || paths.some((path) => !/^lib\/[a-zA-Z0-9_-]+$/.test(path)))
    throw new Error(`Invalid dependency paths in ${project}/foundry.lock`)
  try {
    const library = resolve(directory, 'lib')
    const entry = lstatSync(library, { throwIfNoEntry: false })
    if (entry && (!entry.isDirectory() || entry.isSymbolicLink()))
      throw new Error(`Invalid dependency directory ${library}`)
    const installed = entry ? readdirSync(library) : []
    if (installed.some((name) => !paths.includes(`lib/${name}`)))
      throw new Error('Contains an unpinned library')
    for (const path of paths) {
      const dependency = resolve(directory, path)
      const expected = lock[path]!.tag?.rev ?? lock[path]!.rev
      if (!expected || !/^[0-9a-f]{40}$/.test(expected))
        throw new Error(`Invalid revision for ${path}`)
      if (allowMissing && !lstatSync(dependency, { throwIfNoEntry: false })) continue
      assertDependencyCheckout(dependency, expected)
    }
  } catch (cause) {
    throw new Error(
      `Devnet ${project} dependency sources must be clean and pinned; remove altered libraries and run pnpm deps`,
      { cause },
    )
  }
}

function assertDependencyCheckout(directory: string, expected: string) {
  if (lstatSync(directory).isSymbolicLink()) throw new Error(`Symlinked dependency ${directory}`)
  const git = (...args: string[]) =>
    execFileSync('git', args, { cwd: directory, encoding: 'utf8', stdio: 'pipe' }).trim()
  // Without its own checkout, Git silently discovers the enclosing repository instead.
  if (
    realpathSync(git('rev-parse', '--show-toplevel')) !== realpathSync(directory) ||
    git('rev-parse', '--verify', 'HEAD') !== expected
  )
    throw new Error(`${directory} is not at its pinned revision`)
  if (
    git('status', '--porcelain', '--untracked-files=all', '--ignored', '--ignore-submodules=none')
  )
    throw new Error(`${directory} contains unpublished input`)
  for (const entry of git('ls-tree', '-rz', 'HEAD').split('\0')) {
    if (!entry.startsWith('160000 commit ')) continue
    const [metadata, path] = entry.split('\t')
    const submodule = resolve(directory, path!)
    // pnpm deps leaves upstream test-only submodules empty; populated ones are build input too.
    if (!existsSync(submodule) || readdirSync(submodule).length === 0) continue
    assertDependencyCheckout(submodule, metadata!.slice('160000 commit '.length))
  }
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
