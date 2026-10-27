import { execFileSync } from 'node:child_process'
import { resolve } from 'node:path'

/** Earn builds, tests, and deploys with the `forge` on PATH, which must be stable Foundry v1.8.6 or newer. */
export function assertFoundryVersion(root: string) {
  const forgeVersion = execFileSync('forge', ['--version'], { cwd: root, encoding: 'utf8' })
  const match = /forge Version:\s*(\d+)\.(\d+)\.(\d+)/i.exec(forgeVersion)
  if (!match) throw new Error(`Could not parse Foundry version from: ${forgeVersion.trim()}`)
  const [major, minor, patch] = match.slice(1).map(Number) as [number, number, number]
  if (major * 1e6 + minor * 1e3 + patch < 1_008_006) {
    throw new Error(`Earn requires Foundry v1.8.6 or newer, found ${match[0]}`)
  }
}

/** Forge receives only the deployment signer; independent authority keys stay in this process. */
export function foundryProcessEnvironment(
  environment: Readonly<Record<string, string | undefined>>,
): Record<string, string> {
  const allowed = [
    'PATH',
    'HOME',
    'USER',
    'LOGNAME',
    'SHELL',
    'TMPDIR',
    'TMP',
    'TEMP',
    'LANG',
    'LC_ALL',
    'TERM',
    'NO_COLOR',
    'CI',
    'HTTP_PROXY',
    'HTTPS_PROXY',
    'ALL_PROXY',
    'NO_PROXY',
    'SSL_CERT_FILE',
    'SSL_CERT_DIR',
    'FOUNDRY_PROFILE',
    'RUST_BACKTRACE',
    'RUST_LOG',
    'DEPLOYER_PRIVATE_KEY',
  ]
  const sanitized: Record<string, string> = {}
  for (const key of allowed) {
    const value = environment[key]
    if (value !== undefined) sanitized[key] = value
  }
  sanitized.FOUNDRY_PROFILE = 'deploy'
  return sanitized
}

/** Source verification compiles and reads only; it never receives a transaction signer. */
export function foundryVerificationEnvironment(
  environment: Readonly<Record<string, string | undefined>>,
) {
  const sanitized = foundryProcessEnvironment(environment)
  delete sanitized.DEPLOYER_PRIVATE_KEY
  return sanitized
}

/**
 * The `forge verify-contract` arguments that make Tempo's source verifier rebuild with the compiler
 * the deploy profile uses. Forge reports a solar build to the verifier as the solc version solar
 * emulates, which the verifier compiles with solc and can never match, so for solar this passes the
 * version solar reports as a solc wrapper (`0.8.36+commit.<rev>.solar.<version>`), which names the
 * exact build. Forge drops that build metadata when it looks up its compilation cache unless the
 * compilation profile is named. Any other compiler needs no arguments.
 */
export function sourceVerificationCompilerArguments(
  root: string,
  environment: Readonly<Record<string, string | undefined>> = process.env,
): string[] {
  const env = foundryVerificationEnvironment(environment)
  const config = JSON.parse(
    execFileSync('forge', ['config', '--json'], { cwd: root, encoding: 'utf8', env }),
  ) as { solc?: string | null }
  if (!config.solc || !/[\\/]/.test(config.solc)) return []
  const version = solcWrapperVersion(
    execFileSync(resolve(root, config.solc), ['--version'], { cwd: root, encoding: 'utf8', env }),
  )
  return version ? ['--compiler-version', version, '--compilation-profile', 'default'] : []
}

/** The solar build a solc-wrapper `--version` output names, or null for any other compiler. */
export function solcWrapperVersion(output: string) {
  return (
    /^Version: (\d+\.\d+\.\d+\+commit\.[0-9a-f]+\.solar\.\d+\.\d+\.\d+)\s*$/m.exec(output)?.[1] ??
    null
  )
}
