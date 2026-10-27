import { describe, expect, test, vi } from 'vitest'
import { keccak256 } from 'viem'

import { parseEarnDeploymentProfile } from './profile.js'
import type { EarnDeploymentRecord } from './record.js'
import {
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
    expect(spawnOptions?.env).toEqual({ PATH: '/bin', FOUNDRY_PROFILE: 'deploy' })
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
    expect(spawnOptions?.env).toEqual({ PATH: '/bin', FOUNDRY_PROFILE: 'deploy' })
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
          settlers: [address('5e')],
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
      let routerLookups = 0
      runtime.fetch = vi.fn(async (input) => {
        const url = String(input)
        if (url.endsWith('/v2/verify/job')) {
          return Response.json({ isJobCompleted: true, contract: { address: router }, error: null })
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
      'src/ZoneRouter.sol': 'canonical:router/src/ZoneRouter.sol',
      '../earn/src/interfaces/core/IEarnVault.sol': 'canonical:src/interfaces/core/IEarnVault.sol',
    })
    await expect(result).resolves.toMatchObject({
      contracts: { zoneRouter: { name: 'ZoneRouter', match: 'match' } },
    })
    const [, arguments_, spawnOptions] = vi.mocked(runtime.spawn).mock.calls[0]!
    expect(arguments_).toEqual(
      expect.arrayContaining(['--root', '/checkout/router', 'src/ZoneRouter.sol:ZoneRouter']),
    )
    expect(spawnOptions?.cwd).toBe('/checkout/router')
    expect(runtime.compilerArguments).toHaveBeenCalledWith('/checkout/router', expect.any(Object))

    await expect(
      verify({
        'src/ZoneRouter.sol': 'canonical:router/src/ZoneRouter.sol',
        '../../outside/Secret.sol': 'canonical:outside',
      }).result,
    ).rejects.toThrow('Verifier source path ../../outside/Secret.sol escapes the repository root')
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
