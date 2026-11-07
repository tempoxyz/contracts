import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, test, vi } from 'vitest'
import { parseEarnDeploymentProfile } from '@tempoxyz/contracts/deployments/operations'
import { getAddress, keccak256, zeroAddress, type Hex } from 'viem'
import { Addresses } from 'viem/tempo'

import { foundryProcessEnvironment } from '../chain/foundry.js'
import {
  foundryOutputPath,
  foundryBroadcastPath,
  lockPendingDeployment,
  stageFoundryOutputs,
  loadPendingDeployment,
  restorePendingDeployment,
  savePendingDeployment,
  syncFoundryOutputs,
} from './pending.js'
import { validateSharedFactoryRelease } from './releases.js'
import { resolvedEngineStateSatisfied } from '../modules/earn/engines/steps.js'
import { componentDeploymentIntentHashes, engineOwnerAccepted } from './profile.js'
import { planEarnDeployment } from './plan.js'
import {
  preflightEarnDeployment,
  prepareLifecycleStep,
  recordAuthorityAction,
  recordFoundryAction,
} from './reconcile.js'
import { deploymentStep } from '../modules/index.js'
import * as Inspection from './inspection.js'
import { pendingDeploymentPath } from './bundle.js'

const chain = vi.hoisted(() => ({
  getBlockNumber: vi.fn(async () => 250_000n),
  getChainId: vi.fn(async () => 4217),
  getTransactionReceipt: vi.fn(
    async (_parameters: { hash: Hex }): Promise<{ transactionHash: Hex; status: string }> => {
      throw new Error('Unexpected receipt request')
    },
  ),
  getLogs: vi.fn(
    async (_parameters: { fromBlock: bigint }): Promise<{ transactionHash: string }[]> => [],
  ),
  getCode: vi.fn(async (_parameters: { address: string }): Promise<string> => '0x60'),
  readContract: vi.fn(),
}))
vi.mock(import('../chain/runtime.js'), async (original) => ({
  ...(await original()),
  rpcClient: () => chain as never,
}))

const address = (suffix: string) => getAddress(`0x${suffix.padStart(40, '0')}`)
const engineFactory = address('5')
const profile = parseEarnDeploymentProfile(
  {
    version: 1,
    id: 'pending-test',
    chainId: 4217,
    owner: address('4'),
    engine: { kind: 'veda', address: address('1') },
  },
  { deployer: address('2'), factories: { earn: address('3'), erc4626Engine: address('5') } },
)
describe('Earn deployment lifecycle', () => {
  test('normalizes factory immutables while preserving all executable runtime bytes', async () => {
    const vaultImplementation = address('6')
    const feesImplementation = address('7')
    let factoryCode: Hex = '0x01ff0304'
    const runtimeCode = {
      [vaultImplementation]: '0x02',
      [feesImplementation]: '0x03',
      [engineFactory]: '0x04',
    } as const
    const client = {
      readContract: vi.fn(async ({ functionName }: { functionName: string }) => {
        if (functionName === 'tip20Factory') return Addresses.tip20Factory
        if (functionName === 'earnVaultImplementation') return vaultImplementation
        if (functionName === 'earnFeesImplementation') return feesImplementation
        throw new Error(`unexpected ${functionName}`)
      }),
      getCode: vi.fn(async ({ address: target }: { address: string }) =>
        target === profile.factories.earn
          ? factoryCode
          : runtimeCode[target as keyof typeof runtimeCode],
      ),
    }
    const expected = {
      earnFactory: {
        hash: keccak256('0x01000304'),
        immutableReferences: [{ start: 1, length: 1 }],
      },
      earnVaultImplementation: keccak256(runtimeCode[vaultImplementation]),
      earnFeesImplementation: keccak256(runtimeCode[feesImplementation]),
      erc4626EngineFactory: keccak256(runtimeCode[engineFactory]),
    }

    await expect(validateSharedFactoryRelease(client as never, profile, expected)).resolves.toBe(
      undefined,
    )
    client.getCode.mockClear()
    const { erc4626EngineFactory: _engineFactory, ...coreOnly } = expected
    await expect(validateSharedFactoryRelease(client as never, profile, coreOnly)).resolves.toBe(
      undefined,
    )
    expect(client.getCode).not.toHaveBeenCalledWith({
      address: engineFactory,
    })
    factoryCode = '0x02ff0304'
    await expect(validateSharedFactoryRelease(client as never, profile, expected)).rejects.toThrow(
      'Earn factory',
    )
    factoryCode = '0x01ff0304'
    await expect(
      validateSharedFactoryRelease(client as never, profile, {
        ...expected,
        earnVaultImplementation: keccak256('0xffff'),
      }),
    ).rejects.toThrow('EarnVault implementation')
  })

  test('accepts only the profile owner or a nonzero matching EarnVault operator', () => {
    expect(engineOwnerAccepted(profile, profile.owner, undefined)).toBe(true)
    expect(engineOwnerAccepted(profile, address('9'), address('9'))).toBe(true)
    expect(engineOwnerAccepted(profile, address('9'), address('7'))).toBe(false)
    expect(engineOwnerAccepted(profile, zeroAddress, zeroAddress)).toBe(false)
  })

  test('rejects an already-bound engine when a recovered core output disagrees', () => {
    expect(
      resolvedEngineStateSatisfied(
        profile,
        { engine: address('1'), asset: address('5'), earnVault: address('7') },
        { asset: address('5'), owner: profile.owner, earnVault: address('8') },
      ),
    ).toBe(false)
  })

  test('does not expose independent authority secrets to Foundry', () => {
    expect(
      foundryProcessEnvironment({
        PATH: '/bin',
        HOME: '/home/test',
        DEPLOYER_PRIVATE_KEY: 'deployer',
        ZONE_ADMIN_PRIVATE_KEY: 'zone',
        TEMPO_API_KEY: 'api',
        GH_TOKEN: 'github',
        UNRELATED_VALUE: 'unrelated',
      }),
    ).toEqual({
      PATH: '/bin',
      HOME: '/home/test',
      DEPLOYER_PRIVATE_KEY: 'deployer',
      FOUNDRY_PROFILE: 'deploy',
    })

    expect(foundryProcessEnvironment({ FOUNDRY_PROFILE: 'audit' })).toEqual({
      FOUNDRY_PROFILE: 'deploy',
    })
  })

  test('rejects pending state reuse across deployment identities', () => {
    const root = mkdtempSync(join(tmpdir(), 'earn-lifecycle-'))
    try {
      const profilePath = join(root, 'profile.json')
      savePendingDeployment(profilePath, profile, loadPendingDeployment(profilePath, profile))
      const changed = {
        ...profile,
        core: { ...profile.core, migrationMode: 'OperatorEnabled' as const },
      }
      expect(() => loadPendingDeployment(profilePath, changed)).toThrow(
        'does not match this profile',
      )
      const pending = loadPendingDeployment(profilePath, profile)
      for (const other of [changed, { ...profile, deployer: address('9') }])
        expect(() => savePendingDeployment(profilePath, other, pending)).toThrow(
          'does not match this profile',
        )
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  test('retains core progress while invalidating only a changed boost deployment', () => {
    const reward = {
      startTimestamp: 1_900_000_000,
      endTimestamp: 1_900_000_120,
      intervalSeconds: 60,
      targetAnnualRateBps: 300,
      perUserPrincipalCapAssets: '1000000',
      totalPrincipalCapAssets: '10000000',
      treasury: address('c'),
      funding: {
        wallet: address('d'),
      },
    }
    const {
      ownerExplicit: _ownerExplicit,
      factories: _factories,
      deployer: _deployer,
      access: _access,
      core: _core,
      zone: _zone,
      zoneRouter: _zoneRouter,
      ...authoredProfile
    } = profile
    const authored = {
      ...authoredProfile,
    }
    const previous = parseEarnDeploymentProfile(
      { ...authored, boostRewards: reward },
      { deployer: profile.deployer, factories: profile.factories },
    )
    const current = parseEarnDeploymentProfile(
      {
        ...authored,
        boostRewards: { ...reward, treasury: address('e') },
      },
      { deployer: profile.deployer, factories: profile.factories },
    )
    const completed = {
      completedAt: '2026-01-01T00:00:00.000Z',
      verification: 'chain' as const,
      transactions: [],
    }
    const root = mkdtempSync(join(tmpdir(), 'earn-reconcile-'))
    try {
      const restored = restorePendingDeployment(join(root, 'profile.json'), current, {
        componentDeploymentIntentHashes: componentDeploymentIntentHashes(previous),
        addresses: {
          earnVault: address('a'),
          earnMerkleRewardDistributor: address('b'),
        },
        actions: {
          'deploy-core': completed,
          'bind-core': completed,
          'deploy-merkle-distributor': completed,
        },
      })
      expect(restored.actions).toEqual({
        'deploy-core': completed,
        'bind-core': completed,
      })
      expect(restored.outputs).toEqual({ earnVault: address('a') })
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  test('preserves compatible interrupted optional outputs across committed-record restoration', () => {
    const root = mkdtempSync(join(tmpdir(), 'earn-optional-'))
    try {
      const path = join(root, 'profile.json')
      const cached = {
        ...loadPendingDeployment(path, profile),
        latestOutputs: { earnMerkleRewardDistributor: address('a') },
      }
      savePendingDeployment(path, profile, cached)
      const restored = restorePendingDeployment(path, profile, {
        componentDeploymentIntentHashes: componentDeploymentIntentHashes(profile),
        addresses: {},
        actions: {},
      })
      expect(restored.latestOutputs).toEqual(cached.latestOutputs)
      expect(loadPendingDeployment(path, profile).latestOutputs).toEqual(cached.latestOutputs)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  test('rejects unsupported output keys before persistence without poisoning valid state', () => {
    const root = mkdtempSync(join(tmpdir(), 'earn-output-schema-'))
    try {
      const path = join(root, 'profile.json')
      const pending = loadPendingDeployment(path, profile)
      savePendingDeployment(path, profile, pending)
      for (const field of ['outputs', 'latestOutputs'])
        expect(() =>
          savePendingDeployment(path, profile, { ...pending, [field]: { unknown: address('a') } }),
        ).toThrow('unsupported output')
      expect(loadPendingDeployment(path, profile)).toEqual(pending)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  test('isolates staging and receipts for equal profile IDs from different repositories', () => {
    const root = mkdtempSync(join(tmpdir(), 'earn-isolation-'))
    try {
      const first = join(root, 'first', 'profiles', profile.id, 'profile.json')
      const second = join(root, 'second', 'profiles', profile.id, 'profile.json')
      expect(foundryOutputPath(root, first)).not.toBe(foundryOutputPath(root, second))
      expect(foundryBroadcastPath(root, first)).not.toBe(foundryBroadcastPath(root, second))
      for (const path of [first, second]) {
        savePendingDeployment(path, profile, loadPendingDeployment(path, profile))
        stageFoundryOutputs(root, path)
      }
      syncFoundryOutputs(root, second)
      expect(existsSync(foundryOutputPath(root, first))).toBe(true)
      const unlock = lockPendingDeployment(first)
      expect(() => lockPendingDeployment(first)).toThrow('locked by another run')
      const unlockSecond = lockPendingDeployment(second)
      unlockSecond()
      unlock()
      lockPendingDeployment(first)()
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  test('replaces discovered sequencer metadata instead of retaining removed keys', async () => {
    const root = mkdtempSync(join(tmpdir(), 'earn-metadata-'))
    try {
      const path = join(root, 'profile.json')
      savePendingDeployment(path, profile, {
        ...loadPendingDeployment(path, profile),
        outputs: {
          zoneSequencer0: address('a'),
          zoneSequencer1: address('b'),
          zoneSequencer: address('c'),
        },
      })
      const result = await prepareLifecycleStep({
        root,
        profilePath: path,
        profile,
        rpcUrl: 'http://chain.test',
        environment: {},
        actions: [],
        discoveredOutputs: { zoneSequencer0: address('d') },
      })
      expect(result.pending.outputs).toEqual({ zoneSequencer0: address('d') })
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  test('refuses an ownerless unbound engine before deployment but preserves external owner handoffs', async () => {
    const configured = { ...profile, engine: { kind: 'erc4626' as const, address: address('1') } }
    let owner: `0x${string}` = zeroAddress
    chain.getCode.mockResolvedValue('0x60')
    chain.readContract.mockImplementation(
      async ({ functionName }: { functionName: string }) =>
        ({ asset: address('a'), owner, earnVault: zeroAddress })[functionName],
    )
    await expect(preflightEarnDeployment(configured, 'http://chain.test')).rejects.toThrow(
      'has no owner',
    )
    owner = address('f')
    await expect(preflightEarnDeployment(configured, 'http://chain.test')).resolves.toBeUndefined()
  })

  test('preflight inspects the active migrated engine instead of a retired Veda venue', async () => {
    const vault = address('b')
    const currentEngine = address('c')
    const asset = address('d')
    const venue = address('e')
    const migrated = {
      ...profile,
      core: { ...profile.core, migrationMode: 'OperatorEnabled' as const },
    }
    const values: Record<string, Record<string, unknown>> = {
      [address('1')]: { asset, owner: profile.owner, earnVault: vault },
      [vault]: { operator: profile.owner, engine: currentEngine, asset, engineMigrationMode: 1 },
      [currentEngine]: {
        asset,
        owner: profile.owner,
        earnVault: vault,
        supportsInterface: true,
        vault: venue,
      },
    }
    chain.getCode.mockResolvedValue('0x60')
    chain.readContract.mockImplementation(
      async ({ address: target, functionName }: { address: string; functionName: string }) => {
        const value = values[target]?.[functionName]
        if (value === undefined)
          throw new Error(`Unexpected retired-engine read ${target}.${functionName}`)
        return value
      },
    )
    await expect(
      preflightEarnDeployment(migrated, 'http://chain.test', vault),
    ).resolves.toBeUndefined()
    await expect(preflightEarnDeployment(profile, 'http://chain.test', vault)).rejects.toThrow(
      'immutable vault cannot migrate',
    )
  })

  test('recovers an existing bound engine only through its profile predictions before preflight', async () => {
    const core = { earnVault: address('b'), earnShare: address('c'), earnFees: address('d') }
    const configured = { ...profile, engine: { kind: 'erc4626' as const, address: address('1') } }
    const values: Record<string, Record<string, unknown>> = {
      [configured.factories.earn]: {
        predictEarnShare: core.earnShare,
        predictEarnFees: core.earnFees,
      },
      [address('1')]: {
        asset: address('e'),
        owner: configured.owner,
        earnVault: core.earnVault,
        vault: address('f'),
      },
      [core.earnVault]: {
        ...core,
        engine: address('1'),
        asset: address('e'),
        operator: configured.owner,
      },
      [core.earnFees]: { earnVault: core.earnVault },
    }
    chain.getCode.mockResolvedValue('0x60')
    chain.readContract.mockImplementation(
      async ({ address: target, functionName }: { address: string; functionName: string }) =>
        values[target]?.[functionName],
    )
    await expect(preflightEarnDeployment(configured, 'http://chain.test')).resolves.toBeUndefined()
    values[address('1')]!.earnVault = address('9')
    values[address('9')] = { operator: configured.owner }
    await expect(preflightEarnDeployment(configured, 'http://chain.test')).rejects.toThrow(
      "not this profile's predicted vault",
    )
  })

  test('includes computed provenance blockers in the activation authority handoff', async () => {
    const root = mkdtempSync(join(tmpdir(), 'earn-handoff-'))
    const step = deploymentStep('admit-zone-router-account')
    if (step.execution !== 'authority') throw new Error('Expected authority step')
    const inspect = vi.spyOn(Inspection, 'inspectEarnDeployment').mockResolvedValue({
      router: {
        label: 'Zone router provenance',
        status: 'blocked',
        blockers: ['Spender has no reviewed release provenance'],
      },
    })
    const satisfied = vi.spyOn(step, 'satisfied').mockResolvedValue(false)
    const handoff = vi
      .spyOn(step, 'handoff')
      .mockReturnValue('The Zone administrator must approve the account.')
    try {
      const result = await prepareLifecycleStep({
        root,
        profilePath: join(root, 'profile.json'),
        profile,
        rpcUrl: 'http://chain.test',
        environment: {},
        actions: [{ id: step.id } as never],
      })
      if (result.kind !== 'handoff') throw new Error('Expected handoff')
      expect(result.instructions).toContain('Spender has no reviewed release provenance')
      expect(result.instructions).toContain('Review and resolve these blockers before approving')
    } finally {
      inspect.mockRestore()
      satisfied.mockRestore()
      handoff.mockRestore()
      rmSync(root, { recursive: true, force: true })
    }
  })

  test('stages Forge outputs for a profile outside the checkout and syncs them back', () => {
    const root = mkdtempSync(join(tmpdir(), 'earn-staging-'))
    try {
      const inside = join(root, 'profiles', profile.id, 'profile.json')
      expect(foundryOutputPath(root, inside)).toBe(pendingDeploymentPath(inside))
      const outside = join(root, 'deployments', 'profiles', profile.id, 'profile.json')
      const staged = foundryOutputPath(root, outside)
      expect(staged).toContain(join(root, '.earn', 'external', `${profile.id}-`))

      savePendingDeployment(outside, profile, loadPendingDeployment(outside, profile))
      const pending = JSON.parse(readFileSync(pendingDeploymentPath(outside), 'utf8'))
      const latestOutputs = { earnVault: address('11') }
      mkdirSync(join(staged, '..'), { recursive: true })
      writeFileSync(staged, JSON.stringify({ ...pending, deployer: address('9'), latestOutputs }))
      expect(() => syncFoundryOutputs(root, outside)).toThrow('different deployment')

      writeFileSync(staged, JSON.stringify({ ...pending, latestOutputs }))
      syncFoundryOutputs(root, outside)
      expect(existsSync(join(staged, '..'))).toBe(false)
      expect(loadPendingDeployment(outside, profile).latestOutputs).toEqual(latestOutputs)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  test.each([
    ['inside', ['profiles', profile.id]],
    ['outside', ['deployments', 'profiles', profile.id]],
  ])(
    'recovers an interrupted core broadcast for a profile %s the checkout, records a handoff only once satisfied, and resumes unchanged',
    async (_layout, profileDirectory) => {
      const core = { earnVault: address('11'), earnShare: address('12'), earnFees: address('13') }
      const engine = {
        asset: address('5'),
        owner: address('14'),
        earnVault: zeroAddress,
        // After the interrupted broadcast the stack occupies the predictions.
        predictEarnShare: core.earnShare,
        predictEarnFees: core.earnFees,
      }
      const vault = { engine: address('1'), ...core, asset: engine.asset, operator: profile.owner }
      let broadcasted = false
      chain.getCode.mockImplementation(async ({ address: target }: { address: string }) =>
        broadcasted || !Object.values(core).includes(target as never) ? '0x60' : '0x',
      )
      chain.readContract.mockImplementation(
        async ({ address: target, functionName }: { address: string; functionName: string }) =>
          target === core.earnFees && functionName === 'earnVault'
            ? core.earnVault
            : (target === core.earnVault ? vault : engine)[functionName as never],
      )
      const root = mkdtempSync(join(tmpdir(), 'earn-recovery-'))
      try {
        const options = {
          root,
          profilePath: join(root, ...profileDirectory, 'profile.json'),
          profile,
          rpcUrl: 'http://chain.test',
          environment: {},
        }
        const deploy = await prepareLifecycleStep(options)
        if (deploy.kind !== 'foundry') throw new Error(`planned ${deploy.kind}`)
        expect(deploy.action.id).toBe('deploy-core')
        expect(deploy.arguments).not.toContain(options.rpcUrl)
        expect(deploy.arguments).not.toContain('--rpc-url')
        expect(deploy.environment.FOUNDRY_ETH_RPC_URL).toBe(options.rpcUrl)
        // Forge broadcast and wrote its outputs, then the run stopped before recording them.
        const written = JSON.parse(readFileSync(deploy.outputPath, 'utf8'))
        writeFileSync(deploy.outputPath, JSON.stringify({ ...written, latestOutputs: core }))
        const broadcast = join(root, 'broadcast', 'DeployEarnCore.s.sol', '4217')
        // The shared latest-broadcast file holds another profile's run, so recovery must not trust it.
        const hash: Hex = `0x${'ab'.repeat(32)}`
        const creation: Hex = `0x${'cd'.repeat(32)}`
        chain.getLogs.mockImplementation(async () => [{ transactionHash: creation }])
        broadcasted = true
        mkdirSync(broadcast, { recursive: true })
        writeFileSync(
          join(broadcast, `${deploy.calldata.slice(2, 10)}-latest.json`),
          JSON.stringify({
            transactions: [{ hash }],
            receipts: [{ transactionHash: hash, status: '0x1' }],
          }),
        )

        const handoff = await prepareLifecycleStep(options)
        if (handoff.kind !== 'handoff') throw new Error(`planned ${handoff.kind}`)
        expect(handoff.action.id).toBe('bind-core')
        expect(handoff.pending.actions['deploy-core']?.transactions).toEqual([creation])
        expect(handoff.pending.outputs).toMatchObject(core)
        await expect(
          recordAuthorityAction({ ...options, step: handoff, transactions: [] }),
        ).rejects.toThrow('expected state')

        Object.assign(engine, { owner: profile.owner, earnVault: core.earnVault })
        await recordAuthorityAction({ ...options, step: handoff, transactions: [hash] })
        const complete = await prepareLifecycleStep(options)
        expect(complete.kind).toBe('complete')
        expect(await prepareLifecycleStep(options)).toEqual(complete)
      } finally {
        rmSync(root, { recursive: true, force: true })
      }
    },
  )

  test('runs a step of a sibling Foundry project from that project', async () => {
    const routerProfile = parseEarnDeploymentProfile(
      {
        version: 1,
        id: 'project-test',
        chainId: 4217,
        owner: address('4'),
        engine: { kind: 'veda', address: address('1') },
        zoneRouter: {
          zoneId: 7,
          ops: ['spend'],
          spenders: [address('5e')],
          factory: address('fa'),
        },
      },
      { deployer: address('2'), factories: { earn: address('3'), erc4626Engine: address('5') } },
    )
    chain.getCode.mockImplementation(async () => '0x')
    const checkout = mkdtempSync(join(tmpdir(), 'earn-project-'))
    try {
      const step = await prepareLifecycleStep({
        root: join(checkout, 'earn'),
        profilePath: join(checkout, 'profiles', routerProfile.id, 'profile.json'),
        profile: routerProfile,
        rpcUrl: 'http://chain.test',
        environment: {},
        actions: planEarnDeployment(routerProfile).filter(({ id }) => id === 'deploy-zone-router'),
      })
      if (step.kind !== 'foundry') throw new Error(`planned ${step.kind}`)
      expect(step.root).toBe(join(checkout, 'zone-router'))
      expect(step.arguments.slice(0, 2)).toEqual([
        'script',
        'script/deploy/DeployZoneRouter.s.sol:DeployZoneRouterScript',
      ])
      // Every project's Forge writes outputs to the same staging path, beside Earn's.
      expect(step.outputPath.startsWith(join(checkout, 'earn', '.earn'))).toBe(true)
    } finally {
      rmSync(checkout, { recursive: true, force: true })
    }
  })

  test('adopts a stack another account created from the profile instead of wedging deploy-core', async () => {
    const core = { earnVault: address('21'), earnShare: address('22'), earnFees: address('23') }
    // Someone called the permissionless factory with this profile's exact parameters first.
    const factory = { predictEarnShare: core.earnShare, predictEarnFees: core.earnFees }
    const engine = { asset: address('5'), owner: address('14'), earnVault: zeroAddress }
    const vault = { engine: address('1'), ...core, asset: engine.asset, operator: profile.owner }
    const creation: Hex = `0x${'cd'.repeat(32)}`
    chain.getCode.mockImplementation(async () => '0x60')
    // The creation event sits two log windows behind the head.
    chain.getLogs.mockImplementation(async ({ fromBlock }: { fromBlock: bigint }) =>
      fromBlock === 50_001n ? [{ transactionHash: creation }] : [],
    )
    chain.readContract.mockImplementation(
      async ({ address: target, functionName }: { address: string; functionName: string }) => {
        if (target === profile.factories.earn) return factory[functionName as never]
        if (target === core.earnFees && functionName === 'earnVault') return core.earnVault
        return (target === core.earnVault ? vault : engine)[functionName as never]
      },
    )
    const root = mkdtempSync(join(tmpdir(), 'earn-precreated-'))
    try {
      const step = await prepareLifecycleStep({
        root,
        profilePath: join(root, 'profiles', profile.id, 'profile.json'),
        profile,
        rpcUrl: 'http://chain.test',
        environment: {},
      })
      if (step.kind !== 'handoff') throw new Error(`planned ${step.kind}`)
      expect(step.action.id).toBe('bind-core')
      // A configured engine never runs deploy-engine, so the record's engine and asset come from here.
      expect(step.pending.outputs).toMatchObject({
        ...core,
        engine: vault.engine,
        asset: engine.asset,
      })
      expect(step.pending.actions['deploy-core']?.transactions).toEqual([creation])
      const profilePath = join(root, 'profiles', profile.id, 'profile.json')
      savePendingDeployment(profilePath, profile, { ...step.pending, actions: {} })
      const satisfied = await prepareLifecycleStep({
        root,
        profilePath,
        profile,
        rpcUrl: 'http://chain.test',
        environment: {},
        actions: planEarnDeployment(profile).filter(({ id }) => id === 'deploy-core'),
      })
      expect(satisfied.kind).toBe('complete')
      expect(satisfied.pending.actions['deploy-core']?.transactions).toEqual([creation])
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
  test('records the router creation the factory event names, not a later call that reused it', async () => {
    const routerProfile = parseEarnDeploymentProfile(
      {
        version: 1,
        id: 'reuse-test',
        chainId: 4217,
        owner: address('4'),
        engine: { kind: 'veda', address: address('1') },
        zoneRouter: {
          zoneId: 7,
          ops: ['spend'],
          spenders: [address('5e')],
          factory: address('fa'),
        },
      },
      { deployer: address('2'), factories: { earn: address('3'), erc4626Engine: address('5') } },
    )
    const router = address('9a')
    const creation: Hex = `0x${'c1'.repeat(32)}`
    const reuse: Hex = `0x${'7e'.repeat(32)}`
    const step = deploymentStep('deploy-zone-router')
    if (step.execution !== 'foundry') throw new Error('expected a Foundry step')
    const satisfied = vi.spyOn(step, 'satisfied').mockResolvedValue(true)
    chain.readContract.mockImplementation(async ({ functionName }: { functionName: string }) =>
      functionName === 'predict' ? router : functionName === 'isRouter' ? true : undefined,
    )
    chain.getLogs.mockImplementation(async () => [{ transactionHash: creation }])
    const checkout = mkdtempSync(join(tmpdir(), 'earn-reuse-'))
    try {
      const root = join(checkout, 'earn')
      const profilePath = join(checkout, 'profiles', routerProfile.id, 'profile.json')
      mkdirSync(join(checkout, 'profiles', routerProfile.id), { recursive: true })
      const pending = loadPendingDeployment(profilePath, routerProfile)
      const calldata: Hex = '0x12345678'
      // This run's factory.deploy(mode) succeeded but only returned the router someone created first.
      const broadcast = join(root, 'broadcast', 'DeployZoneRouter.s.sol', '4217')
      mkdirSync(broadcast, { recursive: true })
      writeFileSync(
        join(broadcast, '12345678-latest.json'),
        JSON.stringify({
          transactions: [{ hash: reuse }],
          receipts: [{ transactionHash: reuse, status: '0x1' }],
        }),
      )
      const recorded = await recordFoundryAction({
        root,
        profilePath,
        profile: routerProfile,
        rpcUrl: 'http://chain.test',
        step: {
          kind: 'foundry',
          action: planEarnDeployment(routerProfile).find(({ id }) => id === 'deploy-zone-router')!,
          root: join(checkout, 'zone-router'),
          arguments: ['script', 'script/deploy/DeployZoneRouter.s.sol:DeployZoneRouterScript'],
          environment: {},
          calldata,
          rawGasEstimate: true,
          pending: { ...pending, outputs: { ...pending.outputs, zoneRouter: router } },
          outputPath: join(root, '.earn', 'out.json'),
        },
      })
      expect(recorded.actions['deploy-zone-router']?.transactions).toEqual([creation])
      savePendingDeployment(profilePath, routerProfile, {
        ...pending,
        latestOutputs: { zoneRouter: router },
      })
      satisfied.mockImplementation(
        async (_client, _profile, outputs) => outputs.zoneRouter === router,
      )
      const resumed = await prepareLifecycleStep({
        root,
        profilePath,
        profile: routerProfile,
        rpcUrl: 'http://chain.test',
        environment: {},
        actions: planEarnDeployment(routerProfile).filter(({ id }) => id === 'deploy-zone-router'),
      })
      expect(resumed.kind).toBe('complete')
      expect(resumed.pending.actions['deploy-zone-router']?.transactions).toEqual([creation])
    } finally {
      satisfied.mockRestore()
      rmSync(checkout, { recursive: true, force: true })
    }
  })
})

describe('broadcast receipt recovery', () => {
  test.each([
    ['missing receipts', undefined],
    ['empty receipts', []],
    ['unrelated saved receipt', [{ transactionHash: `0x${'cd'.repeat(32)}`, status: '0x1' }]],
    ['unsuccessful saved receipt', [{ transactionHash: `0x${'ab'.repeat(32)}`, status: '0x0' }]],
  ])('confirms an interrupted creation with %s from the RPC', async (_label, receipts) => {
    const fixture = await interruptedFactoryBroadcast()
    try {
      writeFileSync(
        fixture.broadcast,
        JSON.stringify({ transactions: [{ hash: fixture.hash }], receipts }),
      )
      chain.getTransactionReceipt.mockResolvedValue({
        transactionHash: `0x${fixture.hash.slice(2).toUpperCase()}`,
        status: 'success',
      })
      const resumed = await prepareLifecycleStep(fixture.options)
      expect(resumed.kind).toBe('complete')
      expect(resumed.pending.outputs.zoneRouterFactory).toBe(fixture.factory)
      expect(resumed.pending.actions[fixture.deploy.action.id]?.transactions).toEqual([
        fixture.hash,
      ])
      expect(chain.getTransactionReceipt).toHaveBeenCalledExactlyOnceWith({ hash: fixture.hash })
      expect(await prepareLifecycleStep(fixture.options)).toEqual(resumed)
      expect(chain.getTransactionReceipt).toHaveBeenCalledTimes(1)
    } finally {
      fixture.cleanup()
    }
  })

  test('confirms a creation when the normal post-Forge recorder has no saved receipt', async () => {
    const fixture = await interruptedFactoryBroadcast()
    try {
      chain.getTransactionReceipt.mockResolvedValue({
        transactionHash: fixture.hash,
        status: 'success',
      })
      const recorded = await recordFoundryAction({ ...fixture.options, step: fixture.deploy })
      expect(recorded.actions[fixture.deploy.action.id]).toMatchObject({
        transactions: [fixture.hash],
        verification: 'broadcast',
      })
      expect(chain.getTransactionReceipt).toHaveBeenCalledExactlyOnceWith({ hash: fixture.hash })
    } finally {
      fixture.cleanup()
    }
  })

  test('recovers receipts when outputs were saved before the action was recorded', async () => {
    const fixture = await interruptedFactoryBroadcast()
    try {
      const { root, profilePath, profile } = fixture.options
      syncFoundryOutputs(root, profilePath)
      const pending = loadPendingDeployment(profilePath, profile)
      const { latestOutputs, ...previous } = pending
      savePendingDeployment(profilePath, profile, {
        ...previous,
        outputs: { ...previous.outputs, ...latestOutputs },
      })
      chain.getTransactionReceipt.mockResolvedValue({
        transactionHash: fixture.hash,
        status: 'success',
      })
      const resumed = await prepareLifecycleStep(fixture.options)
      expect(resumed.pending.actions[fixture.deploy.action.id]?.transactions).toEqual([
        fixture.hash,
      ])
      expect(chain.getTransactionReceipt).toHaveBeenCalledExactlyOnceWith({ hash: fixture.hash })
    } finally {
      fixture.cleanup()
    }
  })

  test('repairs an earlier chain-only completion without rebroadcasting', async () => {
    const fixture = await interruptedFactoryBroadcast()
    try {
      chain.getTransactionReceipt.mockResolvedValue({
        transactionHash: fixture.hash,
        status: 'reverted',
      })
      const recorded = await recordFoundryAction({ ...fixture.options, step: fixture.deploy })
      expect(recorded.actions[fixture.deploy.action.id]).toMatchObject({
        transactions: [],
        verification: 'chain',
      })
      expect(await prepareLifecycleStep(fixture.options)).toEqual({
        kind: 'complete',
        pending: recorded,
      })
      chain.getTransactionReceipt.mockResolvedValue({
        transactionHash: fixture.hash,
        status: 'success',
      })
      const resumed = await prepareLifecycleStep(fixture.options)
      expect(resumed.kind).toBe('complete')
      expect(resumed.pending.actions[fixture.deploy.action.id]?.transactions).toEqual([
        fixture.hash,
      ])
      expect(loadPendingDeployment(fixture.options.profilePath, fixture.options.profile)).toEqual(
        resumed.pending,
      )
    } finally {
      fixture.cleanup()
    }
  })

  test('retains a successful saved receipt without another RPC lookup', async () => {
    const fixture = await interruptedFactoryBroadcast()
    try {
      writeFileSync(
        fixture.broadcast,
        JSON.stringify({
          transactions: [{ hash: fixture.hash }],
          receipts: [{ transactionHash: fixture.hash, status: '0x1' }],
        }),
      )
      const resumed = await prepareLifecycleStep(fixture.options)
      expect(resumed.pending.actions[fixture.deploy.action.id]?.transactions).toEqual([
        fixture.hash,
      ])
      expect(chain.getTransactionReceipt).not.toHaveBeenCalled()
    } finally {
      fixture.cleanup()
    }
  })

  test.each(['reverted', 'unknown', '0x1'])(
    'does not fabricate successful transactions from RPC status %s',
    async (status) => {
      const fixture = await interruptedFactoryBroadcast()
      try {
        chain.getTransactionReceipt.mockResolvedValue({ transactionHash: fixture.hash, status })
        const resumed = await prepareLifecycleStep(fixture.options)
        // Observed bindings are not creation evidence; strict source verification still rejects this record.
        expect(resumed.pending.actions[fixture.deploy.action.id]).toMatchObject({
          transactions: [],
          verification: 'chain',
        })
      } finally {
        fixture.cleanup()
      }
    },
  )

  test('checks each unsaved receipt and keeps only successful broadcast hashes', async () => {
    const fixture = await interruptedFactoryBroadcast()
    const saved: Hex = `0x${'cd'.repeat(32)}`
    const reverted: Hex = `0x${'ef'.repeat(32)}`
    try {
      writeFileSync(
        fixture.broadcast,
        JSON.stringify({
          transactions: [{ hash: saved }, { hash: reverted }, { hash: fixture.hash }],
          receipts: [{ transactionHash: saved, status: '0x1' }],
        }),
      )
      chain.getTransactionReceipt.mockImplementation(async ({ hash }) => ({
        transactionHash: hash,
        status: hash === reverted ? 'reverted' : 'success',
      }))
      const resumed = await prepareLifecycleStep(fixture.options)
      expect(resumed.pending.actions[fixture.deploy.action.id]?.transactions).toEqual([
        saved,
        fixture.hash,
      ])
      expect(chain.getTransactionReceipt.mock.calls).toEqual([
        [{ hash: reverted }],
        [{ hash: fixture.hash }],
      ])
    } finally {
      fixture.cleanup()
    }
  })

  test.each([
    ['missing file', undefined],
    ['missing hashes', { transactions: [{}] }],
    ['malformed hashes', { transactions: [{ hash: '0x1234' }, { hash: 1234 }] }],
  ])('does not infer a transaction from onchain state with %s', async (_label, broadcast) => {
    const fixture = await interruptedFactoryBroadcast()
    try {
      if (broadcast) writeFileSync(fixture.broadcast, JSON.stringify(broadcast))
      else rmSync(fixture.broadcast)
      const resumed = await prepareLifecycleStep(fixture.options)
      expect(resumed.pending.actions[fixture.deploy.action.id]?.transactions).toEqual([])
      expect(chain.getTransactionReceipt).not.toHaveBeenCalled()
    } finally {
      fixture.cleanup()
    }
  })

  test.each(['mismatched hash', 'receipt unavailable', 'credentialed RPC error'])(
    'preserves an interrupted action for retry after %s',
    async (failure) => {
      const fixture = await interruptedFactoryBroadcast()
      try {
        if (failure === 'mismatched hash')
          chain.getTransactionReceipt.mockResolvedValue({
            transactionHash: `0x${'cd'.repeat(32)}`,
            status: 'success',
          })
        else
          chain.getTransactionReceipt.mockRejectedValue(
            new Error(
              failure === 'credentialed RPC error'
                ? 'RPC https://operator:fake-secret@rpc.example/secret-path failed'
                : 'Receipt not found',
            ),
          )
        await expect(prepareLifecycleStep(fixture.options)).rejects.toThrow(
          failure === 'mismatched hash'
            ? 'different transaction receipt'
            : 'Cannot recover creation receipt',
        )
        if (failure === 'credentialed RPC error') {
          const error = await prepareLifecycleStep(fixture.options).catch((error: Error) => error)
          expect(error).toBeInstanceOf(Error)
          expect(String(error)).not.toContain('fake-secret')
          expect(String(error)).not.toContain('secret-path')
          expect((error as Error).cause).toBeUndefined()
        }
        const pending = loadPendingDeployment(fixture.options.profilePath, fixture.options.profile)
        expect(pending.actions[fixture.deploy.action.id]).toBeUndefined()
        expect(pending.outputs).toEqual({})
        expect(pending.latestOutputs).toEqual({ zoneRouterFactory: fixture.factory })
        chain.getTransactionReceipt.mockResolvedValue({
          transactionHash: fixture.hash,
          status: 'success',
        })
        const resumed = await prepareLifecycleStep(fixture.options)
        expect(resumed.pending.actions[fixture.deploy.action.id]?.transactions).toEqual([
          fixture.hash,
        ])
      } finally {
        fixture.cleanup()
      }
    },
  )
})

async function interruptedFactoryBroadcast() {
  const profile = parseEarnDeploymentProfile(
    {
      version: 1,
      id: 'interrupted-factory',
      chainId: 4217,
      owner: address('4'),
      engine: { kind: 'veda', address: address('1') },
      zoneRouter: { zoneId: 7, ops: ['spend'], spenders: [address('5e')] },
    },
    { deployer: address('2'), factories: { earn: address('3'), erc4626Engine: address('5') } },
  )
  const checkout = mkdtempSync(join(tmpdir(), 'earn-receipt-recovery-'))
  const cleanup = () => rmSync(checkout, { recursive: true, force: true })
  try {
    const options = {
      root: join(checkout, 'earn'),
      profilePath: join(checkout, 'profiles', profile.id, 'profile.json'),
      profile,
      rpcUrl: 'http://chain.test',
      environment: {},
      actions: planEarnDeployment(profile).filter(({ id }) => id === 'deploy-zone-router-factory'),
    }
    chain.getCode.mockResolvedValue('0x')
    chain.readContract.mockImplementation(async ({ functionName }: { functionName: string }) => {
      if (functionName === 'isRouter') return false
      throw new Error(`Unexpected contract read ${functionName}`)
    })
    chain.getTransactionReceipt
      .mockReset()
      .mockRejectedValue(new Error('Unexpected receipt request'))
    const deploy = await prepareLifecycleStep(options)
    if (deploy.kind !== 'foundry') throw new Error(`planned ${deploy.kind}`)
    const factory = address('f1')
    const written = JSON.parse(readFileSync(deploy.outputPath, 'utf8'))
    writeFileSync(
      deploy.outputPath,
      JSON.stringify({ ...written, latestOutputs: { zoneRouterFactory: factory } }),
    )
    const directory = join(
      foundryBroadcastPath(options.root, options.profilePath),
      'DeployZoneRouterFactory.s.sol',
      String(profile.chainId),
    )
    mkdirSync(directory, { recursive: true })
    const broadcast = join(directory, `${deploy.calldata.slice(2, 10)}-latest.json`)
    const hash: Hex = `0x${'ab'.repeat(32)}`
    writeFileSync(broadcast, JSON.stringify({ transactions: [{ hash }] }))
    chain.getCode.mockResolvedValue('0x60')
    return { broadcast, cleanup, deploy, factory, hash, options }
  } catch (error) {
    cleanup()
    throw error
  }
}
