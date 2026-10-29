import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, test, vi } from 'vitest'
import { parseEarnDeploymentProfile } from '@tempoxyz/contracts/deployments/operations'
import { keccak256, zeroAddress, type Hex } from 'viem'
import { Addresses } from 'viem/tempo'

import { foundryProcessEnvironment } from '../chain/foundry.js'
import {
  foundryOutputPath,
  loadPendingDeployment,
  restorePendingDeployment,
  savePendingDeployment,
  syncFoundryOutputs,
} from './pending.js'
import { validateSharedFactoryRelease } from './releases.js'
import { resolvedEngineStateSatisfied } from '../modules/earn/engines/steps.js'
import { componentDeploymentIntentHashes, engineOwnerAccepted } from './profile.js'
import { planEarnDeployment } from './plan.js'
import { prepareLifecycleStep, recordAuthorityAction, recordFoundryAction } from './reconcile.js'
import { deploymentStep } from '../modules/index.js'
import { pendingDeploymentPath } from './bundle.js'

const chain = vi.hoisted(() => ({
  getBlockNumber: vi.fn(async () => 250_000n),
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

const address = (suffix: string) => `0x${suffix.padStart(40, '0')}` as `0x${string}`
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

  test('stages Forge outputs for a profile outside the checkout and syncs them back', () => {
    const root = mkdtempSync(join(tmpdir(), 'earn-staging-'))
    try {
      const inside = join(root, 'profiles', profile.id, 'profile.json')
      expect(foundryOutputPath(root, inside)).toBe(pendingDeploymentPath(inside))
      const outside = join(root, 'deployments', 'profiles', profile.id, 'profile.json')
      const staged = foundryOutputPath(root, outside)
      expect(staged).toBe(join(root, '.earn', 'external', profile.id, 'deployment.pending.json'))

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
      const vault = { engine: address('1'), ...core, operator: profile.owner }
      let broadcasted = false
      chain.getCode.mockImplementation(async ({ address: target }: { address: string }) =>
        broadcasted || !Object.values(core).includes(target as never) ? '0x60' : '0x',
      )
      chain.readContract.mockImplementation(
        async ({ address: target, functionName }: { address: string; functionName: string }) =>
          (target === core.earnVault ? vault : engine)[functionName as never],
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
          settlers: [address('5e')],
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
    const vault = { engine: address('1'), ...core, operator: profile.owner }
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
          settlers: [address('5e')],
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
    } finally {
      satisfied.mockRestore()
      rmSync(checkout, { recursive: true, force: true })
    }
  })
})
