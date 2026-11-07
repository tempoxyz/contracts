import {
  readdirSync,
  mkdtempSync,
  chmodSync,
  writeFileSync,
  rmSync,
  mkdirSync,
  readFileSync,
  existsSync,
} from 'node:fs'
import * as ChildProcess from 'node:child_process'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { tmpdir } from 'node:os'
import { describe, expect, test, vi } from 'vitest'
import {
  encodeAbiParameters,
  encodeEventTopics,
  getAddress,
  getAbiItem,
  keccak256,
  zeroAddress,
  type Hex,
  type TransactionReceipt,
} from 'viem'

import {
  loadEarnProfileBundle,
  loadProfileDeploymentRecord,
  pendingDeploymentPath,
  profileDeploymentPath,
  publishProfileDeploymentRecord,
} from './bundle.js'
import { earnFactoryAbi, erc4626EngineFactoryAbi } from '../abis/index.js'
import * as Runtime from '../chain/runtime.js'
import * as Inspection from './inspection.js'
import * as Provenance from './provenance.js'
import * as Reconcile from './reconcile.js'
import * as Verify from './verify.js'
import { deploymentActions } from './plan.js'
import { runtimeCodeAddressKeysFor, type EarnDeploymentRecord } from './record.js'
import {
  assertNoPublicFixtureAuthority,
  deployEarnProfile,
  publicFixtureAddresses,
  formatCommitReadyOutput,
} from './deploy.js'
import {
  componentDeploymentIntentHashes,
  deploymentIntentHash,
  parseEarnDeploymentProfile,
  profileFactoryDeploymentId,
  type EarnDeploymentProfile,
} from './profile.js'

vi.mock(import('node:child_process'), async (original) => ({ ...(await original()) }))

const root = resolve(fileURLToPath(new URL('../..', import.meta.url)))
const fixtures = publicFixtureAddresses()
const profiles = readdirSync(resolve(root, 'profiles'), { withFileTypes: true })
  .filter((entry) => entry.isDirectory())
  .map(
    (entry) => loadEarnProfileBundle(resolve(root, 'profiles', entry.name, 'profile.json')).profile,
  )

describe('public fixture authority', () => {
  test('reads the .env.example identities', () => {
    expect(fixtures.size).toBeGreaterThan(0)
  })

  test.each(profiles.map((profile) => [profile.id, profile] as const))(
    '%s holds no privileged role with a public fixture identity',
    (_, profile) => {
      expect(() => assertNoPublicFixtureAuthority(profile, fixtures)).not.toThrow()
    },
  )

  test('refuses a privileged role held by a public fixture identity', () => {
    const [fixture] = fixtures
    const profile = profiles[0]!
    expect(() =>
      assertNoPublicFixtureAuthority(
        { ...profile, core: { ...profile.core, emergencyGuardian: fixture! } },
        fixtures,
      ),
    ).toThrow(/emergency guardian is the public fixture identity/)
  })

  test('refuses a live external policy administrator held by a public fixture identity', () => {
    const [fixture] = fixtures
    expect(() =>
      assertNoPublicFixtureAuthority(profiles[0]!, fixtures, [
        ['live policy administrator', fixture!],
      ]),
    ).toThrow('live policy administrator is the public fixture identity')
  })

  test("refuses a slice's privileged role held by a public fixture identity", () => {
    const [fixture] = fixtures
    const profile = profiles[0]!
    const boostRewards = { treasury: fixture! } as NonNullable<
      EarnDeploymentProfile['boostRewards']
    >
    expect(() => assertNoPublicFixtureAuthority({ ...profile, boostRewards }, fixtures)).toThrow(
      /reward treasury is the public fixture identity/,
    )
  })
})

describe('formatCommitReadyOutput', () => {
  test('does not pass authority keys or arbitrary loader hooks to the formatter subprocess', () => {
    const directory = mkdtempSync(join(tmpdir(), 'earn-formatter-'))
    try {
      const executable = join(directory, 'pnpm')
      writeFileSync(
        executable,
        `#!/bin/sh
[ -z "\${DEPLOYER_PRIVATE_KEY+x}" ] || exit 11
[ -z "\${ZONE_ADMIN_PRIVATE_KEY+x}" ] || exit 12
[ -z "\${NODE_OPTIONS+x}" ] || exit 13
exit 0
`,
      )
      chmodSync(executable, 0o700)
      vi.stubEnv('PATH', directory)
      vi.stubEnv('DEPLOYER_PRIVATE_KEY', 'fixture-deployer')
      vi.stubEnv('ZONE_ADMIN_PRIVATE_KEY', 'fixture-authority')
      vi.stubEnv('NODE_OPTIONS', '--trace-warnings')
      expect(() =>
        formatCommitReadyOutput(directory, join(directory, 'deployment.json')),
      ).not.toThrow()
    } finally {
      vi.unstubAllEnvs()
      rmSync(directory, { recursive: true, force: true })
    }
  })
})

describe('deployEarnProfile committed source recovery', () => {
  test('publishes recovered creation evidence before verification without rebroadcasting or changing identity', async () => {
    const fixture = pendingSourceDeployment()
    try {
      const result = await deployEarnProfile(fixture.options)
      expect(result.state).toBe('complete')
      const recovered = {
        ...fixture.record,
        actions: {
          ...fixture.record.actions,
          'deploy-core': {
            ...fixture.record.actions['deploy-core']!,
            transactions: [fixture.creation],
          },
        },
      }
      expect(fixture.verification).toHaveBeenCalledOnce()
      expect(fixture.verification.mock.calls[0]![0].record).toEqual(recovered)
      const verified = fixture.read()
      expect(verified).toEqual({
        ...recovered,
        source: expect.objectContaining({ contractVerification: 'verified' }),
      })
      expect(verified.source.contracts.earnVault).toMatchObject({
        kind: 'erc1967-proxy',
        match: 'exact_match',
      })
      expect(existsSync(pendingDeploymentPath(fixture.options.profilePath))).toBe(false)
      expect(fixture.chain.getLogs).toHaveBeenCalledOnce()
      fixture.assertNoBroadcast()

      // The verified record and its original nonempty transactions are immutable on later resumes.
      const published = readFileSync(fixture.recordPath, 'utf8')
      expect((await deployEarnProfile(fixture.options)).state).toBe('complete')
      expect(readFileSync(fixture.recordPath, 'utf8')).toBe(published)
      expect(fixture.verification).toHaveBeenCalledOnce()
      expect(fixture.chain.getLogs).toHaveBeenCalledOnce()
      fixture.assertNoBroadcast()
    } finally {
      fixture.cleanup()
    }
  })

  test('recovers an earlier engine receipt without moving the claim scan forward or replacing core evidence', async () => {
    const fixture = pendingSourceDeployment({ provisionEngine: true })
    try {
      expect((await deployEarnProfile(fixture.options)).state).toBe('complete')
      const recovered = {
        ...fixture.record,
        deploymentBlock: '8',
        actions: {
          ...fixture.record.actions,
          'deploy-engine': {
            ...fixture.record.actions['deploy-engine']!,
            transactions: [fixture.engineCreation],
          },
        },
      }
      expect(fixture.verification.mock.calls[0]![0].record).toEqual(recovered)
      expect(fixture.read()).toEqual({
        ...recovered,
        source: expect.objectContaining({ contractVerification: 'verified' }),
      })
      expect(fixture.chain.getLogs).toHaveBeenCalledOnce()
      expect(fixture.chain.getLogs.mock.calls[0]![0].address).toBe(
        fixture.record.factories.erc4626Engine,
      )
      const published = readFileSync(fixture.recordPath, 'utf8')
      expect((await deployEarnProfile(fixture.options)).state).toBe('complete')
      expect(readFileSync(fixture.recordPath, 'utf8')).toBe(published)
      expect(fixture.chain.getLogs).toHaveBeenCalledOnce()
      expect(fixture.verification).toHaveBeenCalledOnce()
      fixture.assertNoBroadcast()
    } finally {
      fixture.cleanup()
    }
  })

  test('preserves nonempty creation transactions in a source-pending record', async () => {
    const fixture = pendingSourceDeployment()
    try {
      const record = {
        ...fixture.record,
        actions: {
          ...fixture.record.actions,
          'deploy-core': {
            ...fixture.record.actions['deploy-core']!,
            transactions: [fixture.creation],
          },
        },
      }
      publishProfileDeploymentRecord(fixture.options.profilePath, fixture.options.profile, record)
      fixture.chain.getLogs.mockRejectedValue(new Error('Recorded creation must not be replaced'))
      expect((await deployEarnProfile(fixture.options)).state).toBe('complete')
      expect(fixture.verification.mock.calls[0]![0].record).toEqual(record)
      expect(fixture.read().actions).toEqual(record.actions)
      expect(fixture.chain.getLogs).not.toHaveBeenCalled()
      fixture.assertNoBroadcast()
    } finally {
      fixture.cleanup()
    }
  })

  test.each([false, true])(
    'keeps repaired evidence through verifier downtime and cache-free resume (provision engine: %s)',
    async (provisionEngine) => {
      const fixture = pendingSourceDeployment({ provisionEngine })
      try {
        const fetch = fixture.dependencies.fetch.getMockImplementation()!
        fixture.dependencies.fetch.mockResolvedValue(new Response('{}', { status: 503 }))
        const result = await deployEarnProfile(fixture.options)
        expect(result.state).toBe('verification-pending')
        const pending = fixture.read()
        expect(pending.source).toEqual(fixture.record.source)
        expect(pending.actions['deploy-core']?.transactions).toEqual([fixture.creation])
        expect(pending.actions['bind-core']).toEqual(fixture.record.actions['bind-core'])
        expect(pending.deploymentBlock).toBe(provisionEngine ? '8' : '10')
        if (provisionEngine)
          expect(pending.actions['deploy-engine']?.transactions).toEqual([fixture.engineCreation])

        rmSync(pendingDeploymentPath(fixture.options.profilePath))
        fixture.chain.getLogs.mockRejectedValue(new Error('Creation discovery must not repeat'))
        fixture.dependencies.fetch.mockImplementation(fetch)
        expect((await deployEarnProfile(fixture.options)).state).toBe('complete')
        expect(fixture.verification.mock.calls[1]![0].record).toEqual(pending)
        expect(fixture.read().source.contractVerification).toBe('verified')
        fixture.assertNoBroadcast()
      } finally {
        fixture.cleanup()
      }
    },
  )

  test.each(['missing event', 'reverted receipt', 'later creation bound'])(
    'does not publish an invalid repair after %s',
    async (failure) => {
      const fixture = pendingSourceDeployment()
      try {
        if (failure === 'missing event') fixture.chain.getLogs.mockResolvedValue([])
        if (failure === 'reverted receipt') fixture.receipt.status = 'reverted'
        if (failure === 'later creation bound') {
          // A recovered receipt may widen the scan, but cannot replace an earlier archive-proven bound.
          fixture.receipt.blockNumber = 11n
          publishProfileDeploymentRecord(fixture.options.profilePath, fixture.options.profile, {
            ...fixture.record,
            actions: {
              ...fixture.record.actions,
              'bind-core': { ...fixture.record.actions['bind-core']!, transactions: [] },
            },
          })
        }
        const published = readFileSync(fixture.recordPath, 'utf8')
        await expect(deployEarnProfile(fixture.options)).rejects.toThrow(
          failure === 'missing event'
            ? /did not return EarnStackDeployed/
            : failure === 'reverted receipt'
              ? /not the successful recorded transaction/
              : /earliest recorded receipt/,
        )
        expect(readFileSync(fixture.recordPath, 'utf8')).toBe(published)
        expect(fixture.read().source.contractVerification).toBe('pending')
        expect(fixture.verification).not.toHaveBeenCalled()
        fixture.assertNoBroadcast()
      } finally {
        fixture.cleanup()
      }
    },
  )

  test.each(['missing event', 'reverted receipt', 'unrelated receipt', 'changed runtime'])(
    'does not verify earlier engine recovery with %s',
    async (failure) => {
      const fixture = pendingSourceDeployment({ provisionEngine: true })
      try {
        if (failure === 'missing event') fixture.chain.getLogs.mockResolvedValue([])
        if (failure === 'reverted receipt') fixture.engineReceipt.status = 'reverted'
        if (failure === 'unrelated receipt') fixture.engineReceipt.logs = []
        if (failure === 'changed runtime') {
          const getCode = fixture.chain.getCode.getMockImplementation()!
          fixture.chain.getLogs.mockImplementation(async () => {
            // Change after initial admission to exercise the repaired candidate's provenance check.
            fixture.chain.getCode.mockImplementation(async (parameters) =>
              parameters.address === fixture.record.addresses.engine
                ? '0x6001'
                : getCode(parameters),
            )
            return [{ transactionHash: fixture.engineCreation }]
          })
        }
        const published = readFileSync(fixture.recordPath, 'utf8')
        await expect(deployEarnProfile(fixture.options)).rejects.toThrow(
          failure === 'missing event'
            ? /did not return the factory creation event/
            : failure === 'reverted receipt'
              ? /not the successful recorded transaction/
              : failure === 'unrelated receipt'
                ? /does not prove creation/
                : /Runtime bytecode hash changed/,
        )
        expect(readFileSync(fixture.recordPath, 'utf8')).toBe(published)
        expect(fixture.verification).not.toHaveBeenCalled()
        expect(fixture.read().source).toEqual(fixture.record.source)
        expect(fixture.read().actions['deploy-core']).toEqual(fixture.record.actions['deploy-core'])
        fixture.assertNoBroadcast()
      } finally {
        fixture.cleanup()
      }
    },
  )

  test.each([false, true])(
    'rejects unrelated creation evidence without poisoning a corrected retry (engine: %s)',
    async (provisionEngine) => {
      const fixture = pendingSourceDeployment({ provisionEngine })
      try {
        const receipt = provisionEngine ? fixture.engineReceipt : fixture.receipt
        const unrelated: Hex = `0x${'ff'.repeat(32)}`
        const getReceipt = fixture.chain.getTransactionReceipt.getMockImplementation()!
        fixture.chain.getLogs.mockResolvedValue([{ transactionHash: unrelated }])
        fixture.chain.getTransactionReceipt.mockImplementation(async (parameters) =>
          parameters.hash === unrelated
            ? { ...receipt, transactionHash: unrelated, blockNumber: 7n, logs: [] }
            : getReceipt(parameters),
        )
        const published = readFileSync(fixture.recordPath, 'utf8')
        await expect(deployEarnProfile(fixture.options)).rejects.toThrow(/does not prove creation/)
        expect(readFileSync(fixture.recordPath, 'utf8')).toBe(published)
        expect(fixture.verification).not.toHaveBeenCalled()
        const pending = JSON.parse(
          readFileSync(pendingDeploymentPath(fixture.options.profilePath), 'utf8'),
        )
        expect(
          pending.actions[provisionEngine ? 'deploy-engine' : 'deploy-core'].transactions,
        ).toEqual([])

        fixture.chain.getLogs.mockResolvedValue([{ transactionHash: receipt.transactionHash }])
        expect((await deployEarnProfile(fixture.options)).state).toBe('complete')
        expect(
          fixture.read().actions[provisionEngine ? 'deploy-engine' : 'deploy-core']?.transactions,
        ).toEqual([receipt.transactionHash])
        expect(fixture.read().deploymentBlock).toBe(provisionEngine ? '8' : '10')
        fixture.assertNoBroadcast()
      } finally {
        fixture.cleanup()
      }
    },
  )

  test('never marks the repaired record verified after noncanonical source', async () => {
    const fixture = pendingSourceDeployment()
    try {
      fixture.dependencies.readSource.mockReturnValue('noncanonical source')
      await expect(deployEarnProfile(fixture.options)).rejects.toThrow(/source/)
      expect(fixture.verification).toHaveBeenCalledOnce()
      expect(fixture.read().source).toEqual(fixture.record.source)
      expect(fixture.read().actions['deploy-core']?.transactions).toEqual([fixture.creation])
      fixture.assertNoBroadcast()
    } finally {
      fixture.cleanup()
    }
  })

  test('does not rewrite nonempty invalid source-pending history from an earlier run', async () => {
    const fixture = pendingSourceDeployment()
    try {
      const unrelated: Hex = `0x${'ff'.repeat(32)}`
      const getReceipt = fixture.chain.getTransactionReceipt.getMockImplementation()!
      fixture.chain.getTransactionReceipt.mockImplementation(async (parameters) =>
        parameters.hash === unrelated
          ? { ...fixture.receipt, transactionHash: unrelated, logs: [] }
          : getReceipt(parameters),
      )
      publishProfileDeploymentRecord(fixture.options.profilePath, fixture.options.profile, {
        ...fixture.record,
        actions: {
          ...fixture.record.actions,
          'deploy-core': { ...fixture.record.actions['deploy-core']!, transactions: [unrelated] },
        },
      })
      const published = readFileSync(fixture.recordPath, 'utf8')
      await expect(deployEarnProfile(fixture.options)).rejects.toThrow(/does not prove creation/)
      expect(readFileSync(fixture.recordPath, 'utf8')).toBe(published)
      expect(fixture.chain.getLogs).not.toHaveBeenCalled()
      fixture.assertNoBroadcast()
    } finally {
      fixture.cleanup()
    }
  })

  test('refuses to repair an already-verified record with missing creation evidence', async () => {
    const fixture = pendingSourceDeployment()
    try {
      const record = {
        ...fixture.record,
        actions: {
          ...fixture.record.actions,
          'deploy-core': {
            ...fixture.record.actions['deploy-core']!,
            transactions: [fixture.creation],
          },
        },
      }
      const source = await fixture.verifySources({
        ...fixture.options,
        client: fixture.chain as never,
        record,
      })
      publishProfileDeploymentRecord(fixture.options.profilePath, fixture.options.profile, {
        ...fixture.record,
        source: { ...fixture.record.source, ...source },
      })
      const published = readFileSync(fixture.recordPath, 'utf8')
      await expect(deployEarnProfile(fixture.options)).rejects.toThrow(
        /Missing or ambiguous creation transaction/,
      )
      expect(readFileSync(fixture.recordPath, 'utf8')).toBe(published)
      expect(fixture.chain.getLogs).not.toHaveBeenCalled()
      expect(fixture.verification).not.toHaveBeenCalled()
      fixture.assertNoBroadcast()
    } finally {
      fixture.cleanup()
    }
  })
})

/** Exercises real record publication, reconciliation, provenance, and source checks over read-only RPC fixtures. */
function pendingSourceDeployment({ provisionEngine = false } = {}) {
  const directory = mkdtempSync(join(tmpdir(), 'earn-pending-source-'))
  const address = (suffix: string) => getAddress(`0x${suffix.padStart(40, '0')}`)
  const creation: Hex = `0x${'ab'.repeat(32)}`
  const engineCreation: Hex = `0x${'ac'.repeat(32)}`
  const venue = address('a')
  const binding: Hex = `0x${'cd'.repeat(32)}`
  const genesis: Hex = `0x${'ef'.repeat(32)}`
  const runtime: Hex = '0x6000'
  const vaultImplementation = address('7')
  const feesImplementation = address('8')
  const tip20Factory = address('9')
  const addresses = {
    engine: address('1'),
    earnVault: address('21'),
    earnShare: address('22'),
    earnFees: address('23'),
    asset: address('6'),
  }
  const authored = {
    version: 1,
    id: 'pending-source-test',
    chainId: 4217,
    owner: address('4'),
    engine: provisionEngine
      ? { kind: 'erc4626', venue }
      : { kind: 'veda', address: addresses.engine },
  }
  const profile = parseEarnDeploymentProfile(authored, {
    deployer: address('2'),
    factories: { earn: address('3'), erc4626Engine: address('5') },
  })
  const options = {
    environment: {},
    profile,
    profilePath: join(directory, 'profiles', profile.id, 'profile.json'),
    root: join(directory, 'earn'),
    rpcUrl: 'https://chain.test',
    trustedIdentity: { deployer: profile.deployer, factories: profile.factories },
  }
  mkdirSync(join(directory, 'profiles', profile.id), { recursive: true })
  writeFileSync(options.profilePath, JSON.stringify(authored))
  const recordPath = profileDeploymentPath(options.profilePath)
  const read = () => loadProfileDeploymentRecord(options.profilePath, profile)
  const feesRuntime: Hex = `0x363d3d373d3d3d363d73${feesImplementation.slice(2)}5af43d82803e903d91602b57fd5bf3`
  const code = (target: string) => (target === addresses.earnFees ? feesRuntime : runtime)
  const record: EarnDeploymentRecord = {
    version: 4,
    deploymentId: profile.id,
    deployer: profile.deployer,
    owner: profile.owner,
    factories: profile.factories,
    deploymentIntentHash: deploymentIntentHash(profile),
    componentDeploymentIntentHashes: componentDeploymentIntentHashes(profile),
    target: { chainId: profile.chainId, genesisHash: genesis },
    assetDecimals: 6,
    deploymentBlock: '10',
    generatedAt: '2026-01-01T00:00:00.000Z',
    source: {
      factoryDeploymentId: profileFactoryDeploymentId(profile),
      commit: null,
      treeDirty: null,
      foundryVersion: null,
      contractVerification: 'pending',
      verifierUrl: null,
      contracts: {},
    },
    runtimeCodeHashes: Object.fromEntries(
      runtimeCodeAddressKeysFor(addresses).map((key) => [
        key,
        keccak256(code(addresses[key as keyof typeof addresses])),
      ]),
    ),
    addresses,
    actions: Object.fromEntries(
      deploymentActions(profile).map(({ id }) => [
        id,
        {
          completedAt: '2026-01-01T00:00:00.000Z',
          verification: 'chain',
          transactions:
            id === 'bind-core'
              ? [binding]
              : provisionEngine && id === 'deploy-core'
                ? [creation]
                : [],
        },
      ]),
    ),
  }
  publishProfileDeploymentRecord(options.profilePath, profile, record)
  const event = getAbiItem({ abi: earnFactoryAbi, name: 'EarnStackDeployed' })
  const receipt = {
    status: 'success',
    transactionHash: creation,
    blockNumber: 10n,
    contractAddress: null,
    logs: [
      {
        address: profile.factories.earn,
        removed: false,
        topics: encodeEventTopics({
          abi: earnFactoryAbi,
          eventName: 'EarnStackDeployed',
          args: {
            earnVault: addresses.earnVault,
            earnShare: addresses.earnShare,
            earnFees: addresses.earnFees,
          },
        }),
        data: encodeAbiParameters(
          event.inputs.filter((input) => !input.indexed),
          [
            addresses.engine,
            addresses.asset,
            profile.owner,
            creation,
            zeroAddress,
            zeroAddress,
            0n,
            0,
            0n,
            creation,
            creation,
            creation,
            creation,
          ],
        ),
      },
    ],
  } as Pick<
    TransactionReceipt,
    'status' | 'transactionHash' | 'blockNumber' | 'contractAddress' | 'logs'
  >
  const engineEvent = getAbiItem({ abi: erc4626EngineFactoryAbi, name: 'ERC4626EngineDeployed' })
  const engineReceipt = {
    ...receipt,
    transactionHash: engineCreation,
    blockNumber: 8n,
    logs: [
      {
        address: profile.factories.erc4626Engine,
        removed: false,
        topics: encodeEventTopics({
          abi: erc4626EngineFactoryAbi,
          eventName: 'ERC4626EngineDeployed',
          args: { engine: addresses.engine, vault: venue, owner: profile.deployer },
        }),
        data: encodeAbiParameters(
          engineEvent.inputs.filter((input) => !input.indexed),
          [addresses.asset, profileFactoryDeploymentId(profile), engineCreation],
        ),
      },
    ],
  } as typeof receipt
  const chain = {
    getBlock: vi.fn(async () => ({ hash: genesis })),
    getBlockNumber: vi.fn(async () => 10n),
    getLogs: vi.fn(
      async ({ address: target }: { address: string }): Promise<{ transactionHash: Hex }[]> => [
        { transactionHash: target === profile.factories.erc4626Engine ? engineCreation : creation },
      ],
    ),
    getCode: vi.fn(async ({ address, blockNumber }: { address: string; blockNumber?: bigint }) =>
      blockNumber === 9n ? '0x' : code(address),
    ),
    getTransactionReceipt: vi.fn(async ({ hash }: { hash: Hex }) =>
      hash === engineCreation
        ? engineReceipt
        : hash === creation
          ? receipt
          : { ...receipt, status: 'success', transactionHash: hash, blockNumber: 10n },
    ),
    getStorageAt: vi.fn(async () => `0x${'0'.repeat(24)}${vaultImplementation.slice(2)}`),
    readContract: vi.fn(
      async ({ address: target, functionName }: { address: string; functionName: string }) => {
        const factory = {
          predictEngine: addresses.engine,
          predictEarnShare: addresses.earnShare,
          predictEarnFees: addresses.earnFees,
          tip20Factory,
          earnVaultImplementation: vaultImplementation,
          earnFeesImplementation: feesImplementation,
        }
        const values =
          target === profile.factories.earn || target === profile.factories.erc4626Engine
            ? factory
            : { ...addresses, vault: venue, owner: profile.owner, operator: profile.owner }
        if (!(functionName in values)) throw new Error(`Unexpected contract read ${functionName}`)
        return values[functionName as keyof typeof values]
      },
    ),
  }
  const contracts = new Map([
    [
      addresses.engine.toLowerCase(),
      provisionEngine
        ? 'src/engines/ERC4626Engine.sol:ERC4626Engine'
        : 'src/engines/veda/VedaEngine.sol:VedaEngine',
    ],
    [
      addresses.earnVault.toLowerCase(),
      'lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy',
    ],
  ])
  const dependencies = {
    fetch: vi.fn(async (input: Parameters<typeof fetch>[0]) => {
      const target = [...contracts.keys()].find((address) =>
        String(input).toLowerCase().includes(address),
      )
      if (!target) throw new Error(`Unexpected verifier lookup ${String(input)}`)
      const contract = contracts.get(target)!
      const [source, name] = contract.split(':')
      return Response.json({
        address: target,
        fullyQualifiedName: contract,
        match: 'exact_match',
        name,
        transactionHash:
          provisionEngine && target === addresses.engine.toLowerCase() ? engineCreation : creation,
        sources: { [source!]: { content: `canonical:${source}` } },
      })
    }),
    pause: vi.fn(async () => undefined),
    readSource: vi.fn((path: string) => `canonical:${path.slice(options.root.length + 1)}`),
    spawn: vi.fn(() => {
      throw new Error('Unexpected verifier submission')
    }),
    compilerArguments: vi.fn(() => []),
    sourcePaths: vi.fn((_root: string, contract: string) => [contract.split(':')[0]!]),
  } satisfies Verify.VerificationDependencies
  const verifySources = (parameters: Parameters<typeof Verify.verifyDeploymentSources>[0]) =>
    verifyDeploymentSources(parameters, dependencies)
  const verifyDeploymentSources = Verify.verifyDeploymentSources
  const verifyRecordedDeploymentSources = Verify.verifyRecordedDeploymentSources
  vi.spyOn(Runtime, 'rpcClient').mockReturnValue(chain as never)
  // Binding inspection and preflight have their own tests; reconciliation and creation evidence stay real.
  vi.spyOn(Reconcile, 'preflightEarnDeployment').mockResolvedValue(undefined)
  vi.spyOn(Inspection, 'inspectEarnDeployment').mockResolvedValue({})
  vi.spyOn(Provenance, 'captureDeploymentSource').mockImplementation((options) => ({
    ...record.source,
    contractVerification: options.contractVerification,
    contracts: options.contracts ?? {},
    verifierUrl: Verify.tempoVerifierUrl,
  }))
  const subprocess = vi.spyOn(ChildProcess, 'spawnSync').mockImplementation((command) => {
    if (command !== 'pnpm') throw new Error(`Unexpected subprocess ${command}`)
    return { status: 0, stdout: '', stderr: '' } as never
  })
  const verification = vi
    .spyOn(Verify, 'verifyDeploymentSources')
    .mockImplementation((parameters) => {
      // Verification must see durable evidence, not a repair that exists only in the private cache.
      expect(read()).toEqual(parameters.record)
      return verifySources(parameters)
    })
  vi.spyOn(Verify, 'verifyRecordedDeploymentSources').mockImplementation((parameters) =>
    verifyRecordedDeploymentSources(parameters, dependencies),
  )
  return {
    options,
    record,
    recordPath,
    read,
    creation,
    receipt,
    engineCreation,
    engineReceipt,
    chain,
    dependencies,
    verification,
    verifySources,
    assertNoBroadcast() {
      expect(
        subprocess.mock.calls.every(([command, args]) => command === 'pnpm' && args?.[2] === 'fmt'),
      ).toBe(true)
      expect(dependencies.spawn).not.toHaveBeenCalled()
    },
    cleanup() {
      vi.restoreAllMocks()
      rmSync(directory, { recursive: true, force: true })
    },
  }
}
