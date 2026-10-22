import { execFileSync } from 'node:child_process'

/** Earn builds, tests, and deploys with the `forge` on PATH, which must be stable Foundry v1.8.5 or newer. */
export function assertFoundryVersion(root: string) {
  const forgeVersion = execFileSync('forge', ['--version'], { cwd: root, encoding: 'utf8' })
  const match = /forge Version:\s*(\d+)\.(\d+)\.(\d+)/i.exec(forgeVersion)
  if (!match) throw new Error(`Could not parse Foundry version from: ${forgeVersion.trim()}`)
  const [major, minor, patch] = match.slice(1).map(Number) as [number, number, number]
  if (major * 1e6 + minor * 1e3 + patch < 1_008_005) {
    throw new Error(`Earn requires Foundry v1.8.5 or newer, found ${match[0]}`)
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
