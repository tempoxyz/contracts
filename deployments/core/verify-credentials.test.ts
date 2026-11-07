import { execFileSync } from 'node:child_process'
import { inspect } from 'node:util'
import { describe, expect, test } from 'vitest'

import { parseEarnDeploymentProfile } from './profile.js'
import type { EarnDeploymentRecord } from './record.js'
import {
  tempoVerifierUrl,
  VerifierUnavailableError,
  verifyContractSource,
  verifyDeploymentSources,
  verifyRecordedDeploymentSources,
  type VerificationDependencies,
} from './verify.js'

const username = 'fixture-verifier@user'
const password = 'fixture-verifier/p@ss:word'
const rpcUrl = `https://${encodeURIComponent(username)}:${encodeURIComponent(password)}@rpc.example/`
const environment = { TEMPO_RPC_USERNAME: username, TEMPO_RPC_PASSWORD: password }
const address = `0x${'ab'.repeat(20)}` as const
const sourcePath = 'src/core/Fixture.sol'
const contract = `${sourcePath}:Fixture`
const options = {
  address,
  chainId: 42431,
  constructorArgs: '0x' as const,
  contract,
  environment,
  root: '/repo/earn',
  rpcUrl,
}
const exposed = [
  rpcUrl,
  encodeURIComponent(rpcUrl),
  username,
  password,
  encodeURIComponent(password),
]
const diagnostic = exposed.join(' | ')

describe('verification RPC credential boundaries', () => {
  test.each(['returned', 'thrown'] as const)(
    'sanitizes a %s spawn error and drops its object graph',
    async (kind) => {
      const original = contaminatedError('spawn failed')
      const runtime = dependencies()
      runtime.spawn = (() => {
        if (kind === 'thrown') throw original
        return { ...spawnResult(), error: original }
      }) as unknown as VerificationDependencies['spawn']
      const error = await rejected(verifyContractSource(options, runtime))
      expectSafe(error, false)
      expect(error.message).toContain('spawn failed')
      expect(error).not.toBe(original)
    },
  )

  test('sanitizes a real compiler subprocess failure, including captured stderr and output', async () => {
    const runtime = dependencies()
    runtime.compilerArguments = () => {
      execFileSync(
        process.execPath,
        ['-e', 'process.stderr.write(process.env.FOUNDRY_ETH_RPC_URL); process.exit(1)'],
        { env: { FOUNDRY_ETH_RPC_URL: rpcUrl }, stdio: 'pipe' },
      )
      return []
    }
    const error = await rejected(verifyContractSource(options, runtime))
    expectSafe(error, false)
    expect(error.message).toContain('Command failed')
  })

  test('sanitizes definitive submission stderr without making it retryable', async () => {
    const runtime = dependencies()
    runtime.spawn = (() =>
      spawnResult(
        `invalid compiler input: ${diagnostic}`,
        1,
      )) as unknown as VerificationDependencies['spawn']
    const error = await rejected(verifyContractSource(options, runtime))
    expectSafe(error, false)
    expect(error.message).toContain('invalid compiler input')
  })

  test('keeps transient submission failures retryable after sanitizing stderr', async () => {
    const runtime = dependencies()
    runtime.spawn = (() =>
      spawnResult(
        `service unavailable: ${diagnostic}`,
        1,
      )) as unknown as VerificationDependencies['spawn']
    const error = await rejected(verifyContractSource(options, runtime))
    expectSafe(error, true)
    expect(error.message).toContain('service unavailable')
  })

  test.each([
    { customCode: 'invalid_input', unavailable: false },
    { customCode: 'compilation_failed', unavailable: true },
  ])(
    'sanitizes $customCode verifier jobs while preserving classification',
    async ({ customCode, unavailable }) => {
      const runtime = dependencies()
      runtime.fetch = (async (input) =>
        String(input).includes('/v2/verify/')
          ? Response.json({
              contract: null,
              error: { customCode, message: `job failed: ${diagnostic}` },
              isJobCompleted: true,
            })
          : new Response('', { status: 404 })) as typeof fetch
      const error = await rejected(verifyContractSource(options, runtime))
      expectSafe(error, unavailable)
      expect(error.message).toContain('job failed')
    },
  )

  test.each(['lookup', 'job'] as const)(
    'sanitizes %s fetch failures without losing retry classification',
    async (stage) => {
      const runtime = dependencies()
      runtime.fetch = (async (input) => {
        if (stage === 'job' && !String(input).includes('/v2/verify/'))
          return new Response('', { status: 404 })
        throw contaminatedError('fetch failed')
      }) as typeof fetch
      const error = await rejected(verifyContractSource(options, runtime))
      expectSafe(error, true)
      expect(error.message).toContain('fetch failed')
    },
  )

  test.each(['lookup', 'job'] as const)(
    'sanitizes %s JSON parsing failures without losing retry classification',
    async (stage) => {
      const runtime = dependencies()
      runtime.fetch = (async (input) => {
        if (stage === 'job' && !String(input).includes('/v2/verify/'))
          return new Response('', { status: 404 })
        const response = new Response('')
        response.json = async () => {
          throw contaminatedError('invalid JSON reply')
        }
        return response
      }) as typeof fetch
      const error = await rejected(verifyContractSource(options, runtime))
      expectSafe(error, true)
      expect(error.message).toContain('invalid JSON reply')
    },
  )

  test('drops nested compiler causes from existing-source validation failures', async () => {
    const runtime = dependencies()
    runtime.fetch = (async () =>
      Response.json({
        address,
        fullyQualifiedName: contract,
        match: 'exact_match',
        name: 'Fixture',
        sources: { [sourcePath]: { content: 'canonical source' } },
      })) as typeof fetch
    runtime.sourcePaths = () => {
      throw contaminatedError('source manifest failed')
    }
    const error = await rejected(verifyContractSource(options, runtime))
    expectSafe(error, false)
    expect(error.message).toContain('source manifest failed')
    expect(error.message).toContain('--resubmit-verification')
  })

  test('sanitizes non-Error throws', async () => {
    const runtime = dependencies()
    runtime.compilerArguments = () => {
      throw `compiler failed: ${diagnostic}`
    }
    expectSafe(await rejected(verifyContractSource(options, runtime)), false)
  })

  test.each(['deployment', 'recorded'] as const)(
    'protects the %s verification entry point',
    async (entry) => {
      const runtime = dependencies()
      runtime.fetch = (async () => {
        throw contaminatedError('fetch failed')
      }) as typeof fetch
      const run = deploymentOptions()
      const promise =
        entry === 'deployment'
          ? verifyDeploymentSources(run, runtime)
          : verifyRecordedDeploymentSources(run, runtime)
      const error = await rejected(promise)
      expectSafe(error, true)
      expect(error.message).toContain('fetch failed')
    },
  )

  test('protects recorded verification before the shared inspection starts', async () => {
    const run = deploymentOptions()
    run.record.source.verifierUrl = rpcUrl
    const error = await rejected(verifyRecordedDeploymentSources(run, dependencies()))
    expectSafe(error, false)
    expect(error.message).toContain('does not match trusted verifier')
  })
})

function contaminatedError(message: string) {
  const error = Object.assign(
    new Error(`${message}: ${diagnostic}`, {
      cause: new Error(`nested secret: ${diagnostic}`),
    }),
    {
      input: rpcUrl,
      output: [null, Buffer.from(rpcUrl), Buffer.from(password)],
      spawnargs: [rpcUrl],
      stderr: password,
      stdout: username,
    },
  )
  error.stack = `original-stack-secret: ${rpcUrl}\n${error.stack}`
  return error
}

function dependencies(): VerificationDependencies {
  return {
    compilerArguments: () => [],
    fetch: (async () => new Response('', { status: 404 })) as typeof fetch,
    pause: async () => undefined,
    readSource: () => 'canonical source',
    sourcePaths: () => [sourcePath],
    spawn: (() => spawnResult()) as unknown as VerificationDependencies['spawn'],
  }
}

function spawnResult(stderr = '', status = 0) {
  return {
    output: ['', 'Verification Job ID: `fixture-job`', stderr],
    pid: 1,
    signal: null,
    status,
    stderr,
    stdout: 'Verification Job ID: `fixture-job`',
  }
}

async function rejected(promise: Promise<unknown>): Promise<Error> {
  const outcome = await promise.then(
    () => undefined,
    (error: unknown) => error,
  )
  expect(outcome).toBeInstanceOf(Error)
  return outcome as Error
}

function expectSafe(error: Error, unavailable: boolean) {
  if (unavailable) expect(error).toBeInstanceOf(VerifierUnavailableError)
  else expect(error).not.toBeInstanceOf(VerifierUnavailableError)
  for (const property of ['cause', 'input', 'output', 'spawnargs', 'stderr', 'stdout'])
    expect(error).not.toHaveProperty(property)
  const rendered = [
    error.message,
    error.stack,
    String(error),
    inspect(error, { depth: null, showHidden: true }),
    JSON.stringify(error),
  ].join('\n')
  for (const secret of exposed) expect(rendered).not.toContain(secret)
  expect(rendered).not.toContain('original-stack-secret')
}

function deploymentOptions(): Parameters<typeof verifyRecordedDeploymentSources>[0] {
  const profile = parseEarnDeploymentProfile(
    {
      version: 1,
      id: 'credential-boundary',
      chainId: 42431,
      owner: address,
      engine: { kind: 'veda', address },
    },
    { deployer: address, factories: { earn: address, erc4626Engine: address } },
  )
  return {
    // The existing engine's verifier lookup must fail before any chain reads.
    client: {} as Parameters<typeof verifyRecordedDeploymentSources>[0]['client'],
    environment,
    profile,
    record: {
      actions: {},
      addresses: { engine: address, earnVault: address, earnFees: address },
      source: { contractVerification: 'verified', contracts: {}, verifierUrl: tempoVerifierUrl },
    } as unknown as EarnDeploymentRecord,
    root: '/repo/earn',
    rpcUrl,
  }
}
