import { describe, expect, test, vi } from 'vitest'
import { keccak256 } from 'viem'

import { parseEarnDeploymentProfile } from './profile.js'
import type { EarnDeploymentRecord } from './record.js'
import {
  VerifierUnavailableError,
  verifyContractSource,
  verifyDeploymentSources,
  verifyRecordedDeploymentSources,
  type VerificationDependencies,
} from './verify.js'

const address = (suffix: string) => `0x${suffix.padStart(40, '0')}` as const
const transaction = `0x${'1'.repeat(64)}` as const
const engine = address('1')
const earnFees = address('2')
const earnShare = address('3')
const earnVault = address('4')
const coreFactory = address('5')
const tip20Factory = address('6')
const vaultImplementation = address('7')
const feesImplementation = address('8')
const implementationRuntime = '0x6000' as const
const implementationCodeHash = keccak256(implementationRuntime)

const profile = parseEarnDeploymentProfile(
  {
    version: 1,
    id: 'source-verification-test',
    chainId: 42431,
    owner: address('a'),
    engine: { kind: 'veda', address: engine },
  },
  { deployer: address('9'), factories: { earn: coreFactory, erc4626Engine: address('c') } },
)
const actions = {
  'deploy-core': {
    completedAt: '2026-01-01T00:00:00.000Z',
    verification: 'broadcast' as const,
    transactions: [transaction],
  },
  'bind-core': {
    completedAt: '2026-01-01T00:00:00.000Z',
    verification: 'chain' as const,
    transactions: [],
  },
}
const addresses = { asset: address('b'), engine, earnFees, earnShare, earnVault }
const contracts = {
  ERC1967Proxy: 'lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy',
  ERC4626Engine: 'src/engines/ERC4626Engine.sol:ERC4626Engine',
  VedaEngine: 'src/engines/veda/VedaEngine.sol:VedaEngine',
  PropAMMEngine: 'src/engines/propamm/PropAMMEngine.sol:PropAMMEngine',
} as const

function verifiedContract(verifiedAddress: string, name: keyof typeof contracts) {
  const fullyQualifiedName = contracts[name]
  const sourcePath = fullyQualifiedName.slice(0, fullyQualifiedName.lastIndexOf(':'))
  return {
    address: verifiedAddress,
    fullyQualifiedName,
    match: 'exact_match',
    name,
    sources: { [sourcePath]: { content: `canonical:${sourcePath}` } },
    transactionHash: name === 'ERC1967Proxy' ? transaction : undefined,
  }
}

function dependencies(engineName = 'VedaEngine') {
  const names = new Map([
    [engine.toLowerCase(), engineName],
    [earnVault.toLowerCase(), 'ERC1967Proxy'],
  ])
  return {
    fetch: vi.fn(async (input) => {
      const url = String(input)
      const matched = [...names].find(([candidate]) => url.toLowerCase().includes(candidate))
      if (!matched) return new Response('{}', { status: 404 })
      const [verifiedAddress, name] = matched as [string, keyof typeof contracts]
      return Response.json(verifiedContract(verifiedAddress, name))
    }) as unknown as typeof fetch,
    pause: vi.fn(async () => undefined),
    readSource: vi.fn((path: string) => `canonical:${path.replace('/repo/', '')}`),
    spawn: vi.fn(),
    compilerArguments: vi.fn((): string[] => []),
    sourcePaths: vi.fn((_root: string, contract: string) => [
      contract.slice(0, contract.lastIndexOf(':')),
    ]),
  } satisfies VerificationDependencies
}

function client() {
  return {
    getCode: vi.fn(async ({ address: requested }: { address: string }) =>
      requested.toLowerCase() === earnFees.toLowerCase()
        ? `0x363d3d373d3d3d363d73${feesImplementation.slice(2)}5af43d82803e903d91602b57fd5bf3`
        : implementationRuntime,
    ),
    getStorageAt: vi.fn(async () => `0x${'0'.repeat(24)}${vaultImplementation.slice(2)}`),
    readContract: vi.fn(async ({ functionName }: { functionName: string }) => {
      if (functionName === 'tip20Factory') return tip20Factory
      if (functionName === 'earnVaultImplementation') return vaultImplementation
      if (functionName === 'earnFeesImplementation') return feesImplementation
      throw new Error(`Unexpected read ${functionName}`)
    }),
  }
}

type RecordedOptions = Parameters<typeof verifyRecordedDeploymentSources>[0]

/** Source verification options over the fixture record; `source` makes it a recorded record. */
function run(
  overrides: Partial<Omit<RecordedOptions, 'record'>> & { record?: object; source?: object } = {},
): RecordedOptions {
  const { record, source, ...rest } = overrides
  return {
    client: client() as never,
    environment: {},
    profile,
    record: (record ??
      (source ? { source, actions, addresses } : { actions, addresses })) as EarnDeploymentRecord,
    root: '/repo',
    rpcUrl: 'https://rpc.example',
    ...rest,
  }
}

describe('deployment source verification', () => {
  test('hashes source inputs in the same order under any operator locale', async () => {
    const runtime = dependencies()
    const engineSources = {
      'lib/forge-std/src/check.sol': { content: 'canonical:lib/forge-std/src/check.sol' },
      'lib/forge-std/src/hash.sol': { content: 'canonical:lib/forge-std/src/hash.sol' },
      'src/engines/veda/VedaEngine.sol': { content: 'canonical:src/engines/veda/VedaEngine.sol' },
    }
    runtime.sourcePaths = vi.fn((_root: string, contract: string) =>
      contract.endsWith(':VedaEngine')
        ? Object.keys(engineSources)
        : [contract.slice(0, contract.lastIndexOf(':'))],
    )
    runtime.fetch = vi.fn(async (input) => {
      const url = String(input)
      if (url.toLowerCase().includes(engine.toLowerCase())) {
        return Response.json({ ...verifiedContract(engine, 'VedaEngine'), sources: engineSources })
      }
      return dependencies().fetch(input)
    }) as unknown as typeof fetch
    const hash = async () =>
      (await verifyDeploymentSources(run(), runtime)).contracts.engine as {
        sourceInputsHash: string
      }
    const expected = (await hash()).sourceInputsHash
    // Czech collation sorts 'ch' after 'h', so check.sol would follow hash.sol under the default.
    const compare = String.prototype.localeCompare
    const czech = vi.spyOn(String.prototype, 'localeCompare').mockImplementation(function (
      this: string,
      that: string,
      locales?: Intl.LocalesArgument,
      options?: Intl.CollatorOptions,
    ) {
      return compare.call(this, that, locales ?? 'cs', options)
    })
    try {
      expect((await hash()).sourceInputsHash).toBe(expected)
    } finally {
      czech.mockRestore()
    }
  })

  test('reports an unreachable verifier as unavailable, and a refusal as definitive', async () => {
    const unreachable = dependencies()
    unreachable.fetch = vi.fn(
      async () => new Response('', { status: 503 }),
    ) as unknown as typeof fetch
    await expect(verifyDeploymentSources(run(), unreachable)).rejects.toBeInstanceOf(
      VerifierUnavailableError,
    )

    const offline = dependencies()
    offline.fetch = vi.fn(async () => {
      throw new TypeError('fetch failed')
    }) as unknown as typeof fetch
    await expect(verifyDeploymentSources(run(), offline)).rejects.toBeInstanceOf(
      VerifierUnavailableError,
    )

    const refused = dependencies()
    refused.fetch = vi.fn(async () => new Response('', { status: 403 })) as unknown as typeof fetch
    const error = await verifyDeploymentSources(run(), refused).catch((caught: unknown) => caught)
    expect(error).toBeInstanceOf(Error)
    expect(error).not.toBeInstanceOf(VerifierUnavailableError)
    expect(refused.fetch).toHaveBeenCalledTimes(1)
  })

  test('treats a non-canonical source as definitive, not unavailable', async () => {
    const runtime = dependencies()
    runtime.readSource = vi.fn(() => 'something else')
    const error = await verifyDeploymentSources(
      run({ submitMissing: true } as never),
      runtime,
    ).catch((caught: unknown) => caught)
    expect(error).toBeInstanceOf(Error)
    expect(error).not.toBeInstanceOf(VerifierUnavailableError)
  })

  test('requires canonical existing PropAMM source and records its verification', async () => {
    const verification = await verifyDeploymentSources(
      run({ profile: { ...profile, engine: { kind: 'propamm', address: engine } } }),
      dependencies('PropAMMEngine'),
    )
    expect(verification.contracts.engine).toMatchObject({ name: 'PropAMMEngine' })
  })

  test('records exact source, ERC-1967, minimal-proxy, and protocol-native provenance', async () => {
    const runtime = dependencies()
    const verification = await verifyDeploymentSources(run(), runtime)

    expect(verification).toEqual({
      contractVerification: 'verified',
      verifierUrl: 'https://contracts.tempo.xyz',
      contracts: {
        engine: {
          kind: 'source',
          name: 'VedaEngine',
          match: 'exact_match',
          sourceInputsHash: expect.stringMatching(/^0x[0-9a-f]{64}$/),
        },
        earnVault: {
          kind: 'erc1967-proxy',
          name: 'ERC1967Proxy',
          match: 'exact_match',
          sourceInputsHash: expect.stringMatching(/^0x[0-9a-f]{64}$/),
          implementation: vaultImplementation,
          implementationCodeHash,
        },
        earnFees: {
          kind: 'minimal-proxy',
          implementation: feesImplementation,
          implementationCodeHash,
        },
        earnShare: { kind: 'protocol-native', factory: tip20Factory },
      },
    })
    expect(runtime.spawn).not.toHaveBeenCalled()
  })

  test('submits a missing factory-created contract and records only an exact match', async () => {
    const erc4626Profile = parseEarnDeploymentProfile(
      {
        version: 1,
        id: 'source-submission-test',
        chainId: 42431,
        owner: address('9'),
        engine: {
          kind: 'erc4626',
          venue: address('d'),
        },
      },
      { deployer: address('1'), factories: { earn: coreFactory, erc4626Engine: address('c') } },
    )
    const runtime = dependencies()
    let engineLookups = 0
    runtime.fetch = vi.fn(async (input) => {
      const url = String(input)
      if (url.endsWith('/v2/verify/job')) {
        return Response.json({
          isJobCompleted: true,
          contract: { address: engine, match: 'exact_match', name: 'ERC4626Engine' },
          error: null,
        })
      }
      if (url.toLowerCase().includes(engine.toLowerCase())) {
        engineLookups++
        return engineLookups === 1
          ? new Response('{}', { status: 404 })
          : Response.json({
              ...verifiedContract(engine, 'ERC4626Engine'),
              transactionHash: transaction,
            })
      }
      return dependencies().fetch(input)
    }) as unknown as typeof fetch
    runtime.spawn = vi.fn(() => ({
      status: 0,
      stdout: '',
      stderr: 'Verification Job ID: `job`',
    })) as unknown as typeof runtime.spawn

    await expect(
      verifyDeploymentSources(
        run({
          environment: {
            PATH: '/bin',
            DEPLOYER_PRIVATE_KEY: 'must-not-leak',
            ZONE_ADMIN_PRIVATE_KEY: 'must-not-leak',
          },
          profile: erc4626Profile,
          record: {
            actions: {
              ...actions,
              'deploy-engine': {
                completedAt: '2026-01-01T00:00:00.000Z',
                verification: 'broadcast',
                transactions: [transaction],
              },
            },
            addresses,
          },
        }),
        runtime,
      ),
    ).resolves.toMatchObject({
      contracts: { engine: { name: 'ERC4626Engine', match: 'exact_match' } },
    })
    expect(runtime.spawn).toHaveBeenCalledTimes(1)
    const [, arguments_, spawnOptions] = runtime.spawn.mock.calls[0]!
    expect(arguments_).toEqual(
      expect.arrayContaining([
        'verify-contract',
        engine,
        'src/engines/ERC4626Engine.sol:ERC4626Engine',
        '--creation-transaction-hash',
        transaction,
      ]),
    )
    expect(spawnOptions?.env).toEqual({
      PATH: '/bin',
      FOUNDRY_PROFILE: 'deploy',
      FOUNDRY_ETH_RPC_URL: 'https://rpc.example',
    })
    expect(arguments_).not.toContain('--rpc-url')
  })

  test('retries a submission the verifier failed, and fails a compile error at once', async () => {
    const erc4626Profile = parseEarnDeploymentProfile(
      {
        version: 1,
        id: 'source-submission-failure-test',
        chainId: 42431,
        owner: address('9'),
        engine: { kind: 'erc4626', venue: address('d') },
      },
      { deployer: address('1'), factories: { earn: coreFactory, erc4626Engine: address('c') } },
    )
    const submitting = (stderr: string) => {
      const runtime = dependencies()
      runtime.fetch = vi.fn(async (input) =>
        String(input).toLowerCase().includes(engine.toLowerCase())
          ? new Response('{}', { status: 404 })
          : dependencies().fetch(input),
      ) as unknown as typeof fetch
      runtime.spawn = vi.fn(() => ({
        status: 1,
        stdout: '',
        stderr,
      })) as unknown as typeof runtime.spawn
      return runtime
    }
    const options = run({
      profile: erc4626Profile,
      record: {
        actions: {
          ...actions,
          'deploy-engine': {
            completedAt: '2026-01-01T00:00:00.000Z',
            verification: 'broadcast',
            transactions: [transaction],
          },
        },
        addresses,
      },
    })

    const rateLimited = submitting('Error: request failed with status code 429 Too Many Requests')
    await expect(verifyDeploymentSources(options, rateLimited)).rejects.toBeInstanceOf(
      VerifierUnavailableError,
    )
    expect(rateLimited.spawn).toHaveBeenCalledTimes(6)

    const failedJob = submitting('')
    failedJob.spawn = vi.fn(() => ({
      status: 0,
      stdout: '',
      stderr: 'Verification Job ID: `job`',
    })) as unknown as typeof failedJob.spawn
    const lookup = failedJob.fetch
    failedJob.fetch = vi.fn(async (input) =>
      String(input).endsWith('/v2/verify/job')
        ? Response.json({
            isJobCompleted: true,
            contract: { address: engine, chainId: '42431', match: null },
            error: { customCode: 'internal_error', message: 'try again' },
          })
        : lookup(input),
    ) as unknown as typeof fetch
    await expect(verifyDeploymentSources(options, failedJob)).rejects.toBeInstanceOf(
      VerifierUnavailableError,
    )
    expect(failedJob.spawn).toHaveBeenCalledTimes(6)

    const timedOut = submitting('')
    timedOut.fetch = vi.fn(async () => new Response('', { status: 408 })) as unknown as typeof fetch
    await expect(verifyDeploymentSources(options, timedOut)).rejects.toBeInstanceOf(
      VerifierUnavailableError,
    )

    const compileError = submitting('Error: Compiler run failed')
    const error = await verifyDeploymentSources(options, compileError).catch(
      (caught: unknown) => caught,
    )
    expect(error).toBeInstanceOf(Error)
    expect(error).not.toBeInstanceOf(VerifierUnavailableError)
    expect(compileError.spawn).toHaveBeenCalledTimes(1)
  })

  test('submits with the solar build the deploy profile compiles with', async () => {
    const erc4626Profile = parseEarnDeploymentProfile(
      {
        version: 1,
        id: 'source-submission-test',
        chainId: 42431,
        owner: address('9'),
        engine: {
          kind: 'erc4626',
          venue: address('d'),
        },
      },
      { deployer: address('1'), factories: { earn: coreFactory, erc4626Engine: address('c') } },
    )
    const runtime = dependencies()
    let engineLookups = 0
    runtime.fetch = vi.fn(async (input) => {
      const url = String(input)
      if (url.endsWith('/v2/verify/job')) {
        return Response.json({
          isJobCompleted: true,
          contract: { address: engine, match: 'exact_match', name: 'ERC4626Engine' },
          error: null,
        })
      }
      if (url.toLowerCase().includes(engine.toLowerCase())) {
        engineLookups++
        return engineLookups === 1
          ? new Response('{}', { status: 404 })
          : Response.json({
              ...verifiedContract(engine, 'ERC4626Engine'),
              transactionHash: transaction,
            })
      }
      return dependencies().fetch(input)
    }) as unknown as typeof fetch
    runtime.compilerArguments = vi.fn(() => [
      '--compiler-version',
      '0.8.36+commit.d83529b.solar.0.2.0',
      '--compilation-profile',
      'default',
    ])
    runtime.spawn = vi.fn(() => ({
      status: 0,
      stdout: '',
      stderr: 'Verification Job ID: `job`',
    })) as unknown as typeof runtime.spawn

    await expect(
      verifyDeploymentSources(
        run({
          environment: {
            PATH: '/bin',
            DEPLOYER_PRIVATE_KEY: 'must-not-leak',
            ZONE_ADMIN_PRIVATE_KEY: 'must-not-leak',
          },
          profile: erc4626Profile,
          record: {
            actions: {
              ...actions,
              'deploy-engine': {
                completedAt: '2026-01-01T00:00:00.000Z',
                verification: 'broadcast',
                transactions: [transaction],
              },
            },
            addresses,
          },
        }),
        runtime,
      ),
    ).resolves.toMatchObject({
      contracts: { engine: { name: 'ERC4626Engine', match: 'exact_match' } },
    })
    expect(runtime.spawn).toHaveBeenCalledTimes(1)
    const [, arguments_, spawnOptions] = runtime.spawn.mock.calls[0]!
    expect(arguments_).toEqual(
      expect.arrayContaining([
        '--compiler-version',
        '0.8.36+commit.d83529b.solar.0.2.0',
        '--compilation-profile',
        'default',
      ]),
    )
    expect(runtime.compilerArguments).toHaveBeenCalledWith('/repo', expect.any(Object))
    expect(spawnOptions?.env).toEqual({
      PATH: '/bin',
      FOUNDRY_PROFILE: 'deploy',
      FOUNDRY_ETH_RPC_URL: 'https://rpc.example',
    })
    expect(arguments_).not.toContain('--rpc-url')
  })

  test('verifies a sibling project contract from its own root, allowing Earn imports', async () => {
    const router = address('70')
    const routerProfile = parseEarnDeploymentProfile(
      {
        version: 1,
        id: 'router-source-test',
        chainId: 42431,
        owner: address('a'),
        engine: { kind: 'veda', address: engine },
        zoneRouter: {
          zoneId: 7,
          ops: ['spend'],
          spenders: [address('5e')],
          factory: address('fac'),
        },
      },
      { deployer: address('9'), factories: { earn: coreFactory, erc4626Engine: address('c') } },
    )
    const verifiedRouter = (sources: Record<string, string>) => ({
      address: router,
      fullyQualifiedName: 'src/ZoneRouter.sol:ZoneRouter',
      match: 'match',
      name: 'ZoneRouter',
      sources: Object.fromEntries(
        Object.entries(sources).map(([path, content]) => [path, { content }]),
      ),
      transactionHash: transaction,
    })
    const verify = (sources: Record<string, string>) => {
      const runtime = dependencies()
      runtime.sourcePaths = vi.fn((_root: string, contract: string) =>
        contract.endsWith(':ZoneRouter')
          ? ['src/ZoneRouter.sol', '../earn/src/interfaces/core/IEarnVault.sol']
          : [contract.slice(0, contract.lastIndexOf(':'))],
      )
      let routerLookups = 0
      runtime.fetch = vi.fn(async (input) => {
        const url = String(input)
        if (url.endsWith('/v2/verify/job')) {
          return Response.json({
            isJobCompleted: true,
            contract: { address: router, match: 'exact_match' },
            error: null,
          })
        }
        if (url.toLowerCase().includes(router.toLowerCase())) {
          return ++routerLookups === 1
            ? new Response('{}', { status: 404 })
            : Response.json(verifiedRouter(sources))
        }
        return dependencies().fetch(input)
      }) as unknown as typeof fetch
      runtime.readSource = vi.fn(
        (path: string) => `canonical:${path.replace(/^\/checkout\/(earn\/)?/, '')}`,
      )
      runtime.spawn = vi.fn(() => ({
        status: 0,
        stdout: '',
        stderr: 'Verification Job ID: `job`',
      })) as unknown as typeof runtime.spawn
      const result = verifyDeploymentSources(
        run({
          root: '/checkout/earn',
          profile: routerProfile,
          record: {
            actions: {
              ...actions,
              'deploy-zone-router': {
                completedAt: '2026-01-01T00:00:00.000Z',
                verification: 'broadcast',
                transactions: [transaction],
              },
            },
            addresses: { ...addresses, zoneRouter: router },
          },
        }),
        runtime,
      )
      return { result, runtime }
    }

    const { result, runtime } = verify({
      'src/ZoneRouter.sol': 'canonical:zone-router/src/ZoneRouter.sol',
      '../earn/src/interfaces/core/IEarnVault.sol': 'canonical:src/interfaces/core/IEarnVault.sol',
    })
    await expect(result).resolves.toMatchObject({
      contracts: { zoneRouter: { name: 'ZoneRouter', match: 'match' } },
    })
    const [, arguments_, spawnOptions] = vi.mocked(runtime.spawn).mock.calls[0]!
    expect(arguments_).toEqual(
      expect.arrayContaining(['--root', '/checkout/zone-router', 'src/ZoneRouter.sol:ZoneRouter']),
    )
    expect(spawnOptions?.cwd).toBe('/checkout/zone-router')
    expect(runtime.compilerArguments).toHaveBeenCalledWith(
      '/checkout/zone-router',
      expect.any(Object),
    )

    await expect(
      verify({
        'src/ZoneRouter.sol': 'canonical:zone-router/src/ZoneRouter.sol',
        '../../outside/Secret.sol': 'canonical:outside',
      }).result,
    ).rejects.toThrow('Verifier source paths do not match the complete compiler input manifest')
  })

  test('read-only verification never submits a missing source', async () => {
    const runtime = dependencies()
    const verified = await verifyDeploymentSources(run(), runtime)
    runtime.fetch = vi.fn(async (input) =>
      String(input).toLowerCase().includes(engine.toLowerCase())
        ? new Response('{}', { status: 404 })
        : dependencies().fetch(input),
    ) as unknown as typeof fetch

    await expect(
      verifyRecordedDeploymentSources(run({ source: verified }), runtime),
    ).rejects.toThrow('is not source verified')
    expect(runtime.spawn).not.toHaveBeenCalled()
  })

  test('rechecks recorded source inputs without requiring the recorded Git object', async () => {
    const runtime = dependencies()
    const verified = await verifyDeploymentSources(run(), runtime)
    vi.mocked(runtime.readSource).mockImplementation(() => 'changed checkout source')
    vi.mocked(runtime.readSource).mockClear()
    const source = { ...verified, commit: `0x${'a'.repeat(40)}` }

    await expect(verifyRecordedDeploymentSources(run({ source }), runtime)).resolves.toBeUndefined()
    expect(runtime.readSource).not.toHaveBeenCalled()
  })

  test('rejects a record-selected verifier instead of contacting it', async () => {
    const runtime = dependencies()
    const verified = await verifyDeploymentSources(run(), runtime)
    vi.mocked(runtime.fetch).mockClear()

    await expect(
      verifyRecordedDeploymentSources(
        run({ source: { ...verified, verifierUrl: 'https://attacker.example' } }),
        runtime,
      ),
    ).rejects.toThrow('does not match trusted verifier')
    expect(runtime.fetch).not.toHaveBeenCalled()
  })

  test('rejects a same-name contract compiled from non-canonical source', async () => {
    const runtime = dependencies()
    runtime.fetch = vi.fn(async (input) => {
      const url = String(input)
      if (!url.toLowerCase().includes(engine.toLowerCase())) return dependencies().fetch(input)
      const lookalike = verifiedContract(engine, 'VedaEngine')
      return Response.json({
        ...lookalike,
        sources: {
          'src/engines/veda/VedaEngine.sol': { content: 'contract VedaEngine { /* lookalike */ }' },
        },
      })
    }) as unknown as typeof fetch

    await expect(verifyDeploymentSources(run(), runtime)).rejects.toThrow(
      'does not match the canonical checkout',
    )
  })

  test('rejects a verifier creation transaction that conflicts with the record', async () => {
    const runtime = dependencies()
    runtime.fetch = vi.fn(async (input) => {
      const url = String(input)
      if (!url.toLowerCase().includes(earnVault.toLowerCase())) return dependencies().fetch(input)
      return Response.json({
        ...verifiedContract(earnVault, 'ERC1967Proxy'),
        transactionHash: `0x${'2'.repeat(64)}`,
      })
    }) as unknown as typeof fetch

    await expect(verifyDeploymentSources(run(), runtime)).rejects.toThrow(
      'does not match the recorded deployment transaction',
    )
  })
})

describe('source verifier admission', () => {
  test.each(['no_match', 'partial', true, {}, 1])(
    'rejects unexpected truthy match %s',
    async (match) => {
      const runtime = dependencies()
      runtime.fetch = async () =>
        Response.json({ ...verifiedContract(engine, 'VedaEngine'), match })
      await expect(verifyDeploymentSources(run(), runtime)).rejects.toThrow('has no source match')
    },
  )

  test('rejects omitted dependencies and injected checkout paths before reading any source', async () => {
    for (const injected of ['../.env', '../README.md', 'src/Secret.sol']) {
      const runtime = dependencies()
      runtime.fetch = async () =>
        Response.json({
          ...verifiedContract(engine, 'VedaEngine'),
          sources: {
            ...verifiedContract(engine, 'VedaEngine').sources,
            [injected]: { content: 'guess' },
          },
        })
      await expect(verifyDeploymentSources(run(), runtime)).rejects.toThrow(
        'complete compiler input manifest',
      )
      expect(runtime.readSource).not.toHaveBeenCalled()
    }
    const runtime = dependencies()
    runtime.sourcePaths.mockReturnValue([
      'src/engines/veda/VedaEngine.sol',
      'src/interfaces/Engine.sol',
    ])
    await expect(verifyDeploymentSources(run(), runtime)).rejects.toThrow(
      'complete compiler input manifest',
    )
    expect(runtime.readSource).not.toHaveBeenCalled()
  })

  test('accepts stronger matches on recheck but refuses downgrades and changed sources', async () => {
    const runtime = dependencies()
    const exact = runtime.fetch
    runtime.fetch = async (input) => {
      const response = await exact(input)
      return Response.json({ ...(await response.json()), match: 'match' })
    }
    const source = await verifyDeploymentSources(run(), runtime)
    runtime.fetch = exact
    await expect(verifyRecordedDeploymentSources(run({ source }), runtime)).resolves.toBeUndefined()
    const stronger = await verifyDeploymentSources(run(), runtime)
    runtime.fetch = async (input) => {
      const response = await exact(input)
      return Response.json({ ...(await response.json()), match: 'match' })
    }
    await expect(
      verifyRecordedDeploymentSources(run({ source: stronger }), runtime),
    ).rejects.toThrow('does not match current provenance')
  })

  test('does not waive the recorded creation hash for a hashless verifier entry', async () => {
    const runtime = dependencies()
    const fetch = runtime.fetch
    runtime.fetch = async (input) => {
      const response = await fetch(input)
      const value = await response.json()
      delete value.transactionHash
      return Response.json(value)
    }
    await expect(verifyDeploymentSources(run(), runtime)).rejects.toThrow(
      'does not match the recorded deployment transaction',
    )
  })

  test('explicit resubmission replaces an invalid existing entry only with canonical evidence', async () => {
    const runtime = dependencies()
    let reads = 0
    runtime.fetch = async (input) =>
      String(input).endsWith('/v2/verify/job')
        ? Response.json({ isJobCompleted: true, contract: { match: 'exact_match' }, error: null })
        : Response.json({
            ...verifiedContract(engine, 'VedaEngine'),
            name: ++reads === 1 ? 'Wrong' : 'VedaEngine',
          })
    runtime.spawn = vi.fn(() => ({
      status: 0,
      stdout: 'Verification Job ID: `job`',
      stderr: '',
    })) as never
    await expect(
      verifyContractSource(
        {
          address: engine,
          chainId: 4217,
          constructorArgs: '0x',
          contract: contracts.VedaEngine,
          environment: {},
          root: '/repo',
          rpcUrl: 'https://rpc.example',
          resubmit: true,
        },
        runtime,
      ),
    ).resolves.toMatchObject({ name: 'VedaEngine', match: 'exact_match' })
    expect(runtime.spawn).toHaveBeenCalledOnce()
  })
})

describe('verifier recovery', () => {
  function repairRuntime(
    transactionHash: string | null | undefined,
    repaired: Record<string, unknown> = {},
    match: 'match' | 'exact_match' = 'match',
  ) {
    const runtime = dependencies()
    const original = runtime.fetch
    let submitted = false
    runtime.fetch = vi.fn(async (input) => {
      const url = String(input)
      if (url.endsWith('/v2/verify/repair'))
        return Response.json({
          isJobCompleted: true,
          contract: { match: 'exact_match' },
          error: null,
        })
      if (!url.toLowerCase().includes(earnVault.toLowerCase())) return original(input)
      return Response.json({
        ...verifiedContract(earnVault, 'ERC1967Proxy'),
        ...(submitted ? repaired : { match, transactionHash }),
      })
    }) as typeof fetch
    runtime.spawn = vi.fn(() => {
      submitted = true
      return { status: 0, stdout: 'Verification Job ID: `repair`', stderr: '' }
    }) as never
    return runtime
  }

  test.each([undefined, null])(
    'repairs creation evidence %s only on opt-in and sends the recorded hash',
    async (transactionHash) => {
      const runtime = repairRuntime(transactionHash)
      await expect(verifyDeploymentSources(run(), runtime)).rejects.toThrow(
        '--resubmit-verification',
      )
      expect(runtime.spawn).not.toHaveBeenCalled()
      await expect(
        verifyDeploymentSources(run({ resubmit: true }), runtime),
      ).resolves.toMatchObject({ contractVerification: 'verified' })
      expect(runtime.spawn).toHaveBeenCalledOnce()
      expect(runtime.spawn).toHaveBeenCalledWith(
        'forge',
        expect.arrayContaining(['--creation-transaction-hash', transaction]),
        expect.anything(),
      )
    },
  )

  test.each([
    { transactionHash: null },
    { transactionHash: `0x${'2'.repeat(64)}` },
    { name: 'Wrong' },
    { fullyQualifiedName: 'src/Lookalike.sol:ERC1967Proxy' },
    { address: address('f') },
    { sources: { [contracts.ERC1967Proxy.split(':')[0]!]: { content: 'wrong source' } } },
  ])('never accepts invalid evidence after a successful job: %j', async (repaired) => {
    const runtime = repairRuntime(null, repaired)
    await expect(verifyDeploymentSources(run({ resubmit: true }), runtime)).rejects.toThrow()
    expect(runtime.spawn).toHaveBeenCalledOnce()
  })

  test('leaves valid exact matches untouched during an explicit repair', async () => {
    const runtime = dependencies()
    await expect(verifyDeploymentSources(run({ resubmit: true }), runtime)).resolves.toMatchObject({
      contractVerification: 'verified',
    })
    expect(runtime.spawn).not.toHaveBeenCalled()
  })

  test('rechecks a record read-only by default and repairs it only on explicit opt-in', async () => {
    const source = await verifyDeploymentSources(run(), dependencies())
    const runtime = repairRuntime(null)
    const record = run({ source }).record
    const before = structuredClone(record)
    await expect(verifyRecordedDeploymentSources(run({ record }), runtime)).rejects.toThrow(
      'does not match the recorded deployment transaction',
    )
    expect(runtime.spawn).not.toHaveBeenCalled()
    await expect(
      verifyRecordedDeploymentSources(run({ record, resubmit: true }), runtime),
    ).resolves.toBeUndefined()
    expect(runtime.spawn).toHaveBeenCalledOnce()
    expect(record).toEqual(before)
  })

  test('refuses incompatible repair sources before submitting anything', async () => {
    const source = await verifyDeploymentSources(run(), dependencies())
    const path = contracts.ERC1967Proxy.split(':')[0]!
    const runtime = repairRuntime(null, {
      sources: { [path]: { content: 'new canonical source' } },
    })
    const original = runtime.readSource
    runtime.readSource = vi.fn((file) =>
      file === `/repo/${path}` ? 'new canonical source' : original(file),
    )
    await expect(
      verifyRecordedDeploymentSources(run({ source, resubmit: true }), runtime),
    ).rejects.toThrow('Use the recorded source revision')
    expect(runtime.spawn).not.toHaveBeenCalled()
  })

  test.each(['match', 'exact_match'] as const)(
    'leaves historical %s entries untouched from a newer checkout during repair',
    async (match) => {
      const runtime = dependencies()
      const original = runtime.fetch
      runtime.fetch = async (input) => {
        const response = await original(input)
        return Response.json({ ...(await response.json()), match })
      }
      const source = await verifyDeploymentSources(run(), runtime)
      runtime.readSource.mockImplementation(() => 'new checkout sources')
      runtime.readSource.mockClear()
      runtime.sourcePaths.mockClear()
      await expect(
        verifyRecordedDeploymentSources(run({ source, resubmit: true }), runtime),
      ).resolves.toBeUndefined()
      expect(runtime.spawn).not.toHaveBeenCalled()
      expect(runtime.readSource).not.toHaveBeenCalled()
      expect(runtime.sourcePaths).not.toHaveBeenCalled()
    },
  )

  test('repairs owned evidence without comparing an existing engine to the checkout', async () => {
    const source = await verifyDeploymentSources(run(), dependencies())
    const runtime = repairRuntime(null)
    const readSource = runtime.readSource
    runtime.readSource = vi.fn((file) =>
      file.endsWith('/VedaEngine.sol') ? 'new unrelated engine source' : readSource(file),
    )
    await expect(
      verifyRecordedDeploymentSources(run({ source, resubmit: true }), runtime),
    ).resolves.toBeUndefined()
    expect(runtime.spawn).toHaveBeenCalledOnce()
  })

  test.each(['content', 'manifest', 'missing'] as const)(
    'preflights the complete recorded source set before repair: %s',
    async (change) => {
      const source = await verifyDeploymentSources(run(), dependencies())
      const runtime = repairRuntime(null)
      const sourcePaths = runtime.sourcePaths
      const readSource = runtime.readSource
      runtime.sourcePaths = vi.fn((root, contract) => [
        ...sourcePaths(root, contract),
        ...(change === 'manifest' ? ['src/Added.sol'] : []),
      ])
      runtime.readSource = vi.fn((file) => {
        if (change === 'missing') throw new Error('ENOENT')
        return change === 'content' ? 'changed source' : readSource(file)
      })
      await expect(
        verifyRecordedDeploymentSources(run({ source, resubmit: true }), runtime),
      ).rejects.toThrow('Use the recorded source revision')
      expect(runtime.spawn).not.toHaveBeenCalled()
    },
  )

  test('preflights every needed repair before submitting the first', async () => {
    const deployedEngine = parseEarnDeploymentProfile(
      {
        version: 1,
        id: 'recorded-engine-repair',
        chainId: 42431,
        owner: address('9'),
        engine: { kind: 'erc4626', venue: address('d') },
      },
      { deployer: address('1'), factories: { earn: coreFactory, erc4626Engine: address('c') } },
    )
    const runtime = dependencies('ERC4626Engine')
    const original = runtime.fetch
    let invalid = false
    runtime.fetch = vi.fn(async (input) => {
      const response = await original(input)
      return Response.json({
        ...(await response.json()),
        transactionHash: invalid ? null : transaction,
      })
    }) as typeof fetch
    const options = run({
      profile: deployedEngine,
      record: { addresses, actions: { ...actions, 'deploy-engine': actions['deploy-core'] } },
    })
    const source = await verifyDeploymentSources(options, runtime)
    invalid = true
    const readSource = runtime.readSource
    runtime.readSource = vi.fn((file) =>
      file.endsWith('/ERC1967Proxy.sol') ? 'changed proxy source' : readSource(file),
    )
    await expect(
      verifyRecordedDeploymentSources(
        {
          ...options,
          resubmit: true,
          record: { ...options.record, source } as EarnDeploymentRecord,
        },
        runtime,
      ),
    ).rejects.toThrow('Use the recorded source revision')
    expect(runtime.spawn).not.toHaveBeenCalled()
  })

  test('checks repaired results against historical evidence, not newer source returned by the verifier', async () => {
    const source = await verifyDeploymentSources(run(), dependencies())
    const path = contracts.ERC1967Proxy.split(':')[0]!
    const runtime = repairRuntime(null, { sources: { [path]: { content: 'unrecorded source' } } })
    await expect(
      verifyRecordedDeploymentSources(run({ source, resubmit: true }), runtime),
    ).rejects.toThrow('does not match current provenance')
    expect(runtime.spawn).toHaveBeenCalledOnce()
  })

  test('refuses changed sources after a transient failure before retrying submission', async () => {
    const source = await verifyDeploymentSources(run(), dependencies())
    const runtime = repairRuntime(null)
    runtime.spawn = vi.fn(() => ({
      status: 1,
      stdout: '',
      stderr: 'HTTP status code 503 Service Unavailable',
    })) as never
    runtime.pause = vi.fn(async () => {
      runtime.readSource.mockImplementation(() => 'changed during retry backoff')
    })
    await expect(
      verifyRecordedDeploymentSources(run({ source, resubmit: true }), runtime),
    ).rejects.toThrow('Use the recorded source revision')
    expect(runtime.spawn).toHaveBeenCalledOnce()
    expect(runtime.pause).toHaveBeenCalledOnce()
  })

  test('reports a terminal exact-match refusal without retrying or accepting the old entry', async () => {
    const runtime = repairRuntime(null, {}, 'exact_match')
    runtime.spawn = vi.fn(() => ({
      status: 1,
      stdout: '',
      stderr: 'HTTP 409 already_verified: Contract is already verified',
    })) as never
    const error = await verifyDeploymentSources(run({ resubmit: true }), runtime).catch(
      (caught: unknown) => caught,
    )
    expect(error).not.toBeInstanceOf(VerifierUnavailableError)
    expect(error).toMatchObject({
      message: expect.stringContaining('Verifier-side repair is required'),
    })
    expect(runtime.spawn).toHaveBeenCalledOnce()
    expect(runtime.pause).not.toHaveBeenCalled()
  })
})
