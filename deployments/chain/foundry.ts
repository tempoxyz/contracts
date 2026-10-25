import { execFileSync } from 'node:child_process'
import { basename } from 'node:path'

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
 * Tempo's source verifier (contracts.tempo.xyz, a Sourcify instance) rebuilds each contract with solc,
 * and hosted deployments require that match. A solar build cannot be reproduced there, so a hosted
 * deployment compiled with solar would broadcast and then fail verification.
 */
export function isSourceVerifiableCompiler(solc: string | null | undefined) {
  return !solc || !/solar/i.test(basename(solc))
}

/** Refuses a hosted deployment before it broadcasts when the deploy profile compiles with solar. */
export function assertSourceVerifiableCompiler(
  root: string,
  environment: Readonly<Record<string, string | undefined>> = process.env,
) {
  const config = JSON.parse(
    execFileSync('forge', ['config', '--json'], {
      cwd: root,
      encoding: 'utf8',
      env: foundryVerificationEnvironment(environment),
    }),
  ) as { solc?: string | null }
  if (!isSourceVerifiableCompiler(config.solc)) {
    throw new Error(
      `Earn compiles with solar (${config.solc}), which Tempo's source verifier cannot reproduce; hosted deployments need a source match, so they stay on solc until the verifier supports solar`,
    )
  }
}
