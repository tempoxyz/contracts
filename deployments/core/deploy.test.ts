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
  zeroHash,
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
import { earnFactoryAbi, erc4626EngineFactoryAbi, zoneRouterFactoryAbi } from '../abis/index.js'
import { zoneFactoryAddress, zoneMessengerAddress } from '../chain/zone.js'
import * as Runtime from '../chain/runtime.js'
import * as Inspection from './inspection.js'
import * as Provenance from './provenance.js'
import * as Reconcile from './reconcile.js'
import * as Verify from './verify.js'
import { loadPendingDeployment } from './pending.js'
import { deploymentActions } from './plan.js'
import * as Plan from './plan.js'
import { deploymentStep } from '../modules/index.js'
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

describe('retained historical direct creation', () => {
  test.each(['none', 'source', 'input', 'sender', 'receipt'] as const)(
    'publishes retained history during a verifier outage and rechecks cache-free retry (%s corruption)',
    async (corruption) => {
      const fixture = pendingSourceDeployment({ retainedController: true })
      try {
        const record = structuredClone(fixture.record)
        record.actions['deploy-core']!.transactions = [fixture.creation]
        const source = await fixture.verifySources({
          ...fixture.options,
          client: fixture.chain as never,
          record,
        })
        const verified = { ...record, source: { ...record.source, ...source } }
        publishProfileDeploymentRecord(
          fixture.options.profilePath,
          fixture.options.profile,
          verified,
        )
        fixture.removeBoostRewards()
        const compiler = vi.spyOn(ChildProcess, 'execFileSync').mockReturnValue('0x6002' as never)
        const fetch = fixture.dependencies.fetch.getMockImplementation()!
        fixture.dependencies.fetch.mockResolvedValue(new Response('{}', { status: 503 }))
        // Isolate external activation while exercising its real post-publication dispatch.
        const step = deploymentStep('authorize-router')
        const activationPlan = vi.spyOn(Plan, 'activationActions').mockReturnValue([
          {
            id: step.id,
            authority: step.authority.id,
            execution: step.execution,
            summary: step.summary,
          },
        ])
        const prepare = Reconcile.prepareLifecycleStep
        const activation = vi.fn(async (parameters: Parameters<typeof prepare>[0]) => {
          expect(fixture.read().source.contractVerification).toBe('pending')
          return prepare({ ...parameters, actions: [] })
        })
        const preparation = vi
          .spyOn(Reconcile, 'prepareLifecycleStep')
          .mockImplementation((parameters) =>
            parameters.actions?.[0]?.id === step.id ? activation(parameters) : prepare(parameters),
          )
        const result = await deployEarnProfile(fixture.options)
        expect(result.state).toBe('verification-pending')
        const pending = fixture.read()
        expect(pending.source.contractVerification).toBe('pending')
        expect(pending.source.contracts.earnContributionController).toEqual(
          verified.source.contracts.earnContributionController,
        )
        expect(pending.actions['deploy-contribution-controller']).toEqual(
          verified.actions['deploy-contribution-controller'],
        )
        expect(pending.addresses.earnMerkleRewardDistributor).toBeUndefined()
        expect(activation).toHaveBeenCalledOnce()
        activationPlan.mockRestore()
        preparation.mockRestore()
        rmSync(pendingDeploymentPath(fixture.options.profilePath))
        fixture.dependencies.fetch.mockImplementation(fetch)
        const publishedPending = readFileSync(fixture.recordPath, 'utf8')
        const transaction = { ...fixture.minedTransaction }
        const getReceipt = fixture.chain.getTransactionReceipt.getMockImplementation()!
        const readSource = fixture.dependencies.readSource.getMockImplementation()!
        if (corruption === 'input') fixture.minedTransaction.input = '0x6000'
        if (corruption === 'sender') fixture.minedTransaction.from = zeroAddress
        if (corruption === 'receipt')
          fixture.chain.getTransactionReceipt.mockImplementation(async (parameters) => ({
            ...(await getReceipt(parameters)),
            ...(parameters.hash === transaction.hash ? { contractAddress: zeroAddress } : {}),
          }))
        if (corruption === 'source') {
          fixture.dependencies.fetch.mockImplementation(async (input) => {
            const response = await fetch(input)
            if (
              !String(input)
                .toLowerCase()
                .includes(record.addresses.earnContributionController!.toLowerCase())
            )
              return response
            return Response.json({
              ...((await response.json()) as object),
              sources: {
                'src/rewards/EarnContributionController.sol': { content: 'changed source' },
              },
            })
          })
          // Matching today's checkout cannot replace the historical source-input hash.
          fixture.dependencies.readSource.mockImplementation((path) =>
            path.endsWith('EarnContributionController.sol') ? 'changed source' : readSource(path),
          )
        }
        if (corruption !== 'none') {
          await expect(deployEarnProfile(fixture.options)).rejects.toThrow()
          expect(readFileSync(fixture.recordPath, 'utf8')).toBe(publishedPending)
          Object.assign(fixture.minedTransaction, transaction)
          fixture.chain.getTransactionReceipt.mockImplementation(getReceipt)
          fixture.dependencies.fetch.mockImplementation(fetch)
        }
        // Historical checks do not read the current checkout, even after its source text has changed.
        fixture.dependencies.readSource.mockReturnValue('today’s different source')
        expect((await deployEarnProfile(fixture.options)).state).toBe('complete')
        expect(fixture.read().source.contracts.earnContributionController).toEqual(
          verified.source.contracts.earnContributionController,
        )
        expect(compiler).not.toHaveBeenCalled()
        const published = readFileSync(fixture.recordPath, 'utf8')
        expect((await deployEarnProfile(fixture.options)).state).toBe('complete')
        expect(readFileSync(fixture.recordPath, 'utf8')).toBe(published)
        fixture.assertNoBroadcast()
      } finally {
        fixture.cleanup()
      }
    },
  )
  test('never treats unverified direct creation as retained history during an outage', async () => {
    const fixture = pendingSourceDeployment({ retainedController: true })
    try {
      const record = structuredClone(fixture.record)
      record.actions['deploy-core']!.transactions = [fixture.creation]
      publishProfileDeploymentRecord(fixture.options.profilePath, fixture.options.profile, record)
      fixture.removeBoostRewards()
      const published = readFileSync(fixture.recordPath, 'utf8')
      const compiler = vi.spyOn(ChildProcess, 'execFileSync').mockReturnValue('0x6002' as never)
      fixture.dependencies.fetch.mockResolvedValue(new Response('{}', { status: 503 }))
      await expect(deployEarnProfile(fixture.options)).rejects.toThrow(/unexpected creation input/)
      expect(compiler).toHaveBeenCalledOnce()
      expect(Verify.verifyRecordedStepCreation).not.toHaveBeenCalled()
      expect(readFileSync(fixture.recordPath, 'utf8')).toBe(published)
      fixture.assertNoBroadcast()
    } finally {
      fixture.cleanup()
    }
  })
  test.each(['source', 'input', 'sender', 'receipt'] as const)(
    'rejects corrupt retained %s evidence before publishing a replacement record',
    async (corruption) => {
      const fixture = pendingSourceDeployment({ retainedController: true })
      try {
        const record = structuredClone(fixture.record)
        record.actions['deploy-core']!.transactions = [fixture.creation]
        const source = await fixture.verifySources({
          ...fixture.options,
          client: fixture.chain as never,
          record,
        })
        publishProfileDeploymentRecord(fixture.options.profilePath, fixture.options.profile, {
          ...record,
          source: { ...record.source, ...source },
        })
        fixture.removeBoostRewards()
        const published = readFileSync(fixture.recordPath, 'utf8')
        const compiler = vi.spyOn(ChildProcess, 'execFileSync').mockReturnValue('0x6002' as never)
        if (corruption === 'input') fixture.minedTransaction.input = '0x6000'
        if (corruption === 'sender')
          fixture.minedTransaction.from = getAddress(`0x${'f'.repeat(40)}`)
        if (corruption === 'receipt') {
          const receipt = fixture.chain.getTransactionReceipt.getMockImplementation()!
          fixture.chain.getTransactionReceipt.mockImplementation(async (parameters) => ({
            ...(await receipt(parameters)),
            ...(parameters.hash === fixture.minedTransaction.hash
              ? { contractAddress: zeroAddress }
              : {}),
          }))
        }
        if (corruption === 'source') {
          const fetch = fixture.dependencies.fetch.getMockImplementation()!
          fixture.dependencies.fetch.mockImplementation(async (input) => {
            const response = await fetch(input)
            if (
              !String(input)
                .toLowerCase()
                .includes(record.addresses.earnContributionController!.toLowerCase())
            )
              return response
            return Response.json({
              ...((await response.json()) as object),
              sources: {
                'src/rewards/EarnContributionController.sol': { content: 'corrupt source' },
              },
            })
          })
        }
        await expect(deployEarnProfile(fixture.options)).rejects.toThrow()
        expect(readFileSync(fixture.recordPath, 'utf8')).toBe(published)
        expect(compiler).not.toHaveBeenCalled()
        fixture.assertNoBroadcast()
      } finally {
        fixture.cleanup()
      }
    },
  )
  test('keeps a verified controller when unrelated rewards are removed after compiler settings change', async () => {
    const fixture = pendingSourceDeployment({ retainedController: true })
    try {
      const record = structuredClone(fixture.record)
      record.actions['deploy-core']!.transactions = [fixture.creation]
      const source = await fixture.verifySources({
        ...fixture.options,
        client: fixture.chain as never,
        record,
      })
      const verified = { ...record, source: { ...record.source, ...source } }
      publishProfileDeploymentRecord(fixture.options.profilePath, fixture.options.profile, verified)
      fixture.removeBoostRewards()
      // The source text is unchanged, but today's compiler settings produce different initcode.
      const compiler = vi.spyOn(ChildProcess, 'execFileSync').mockReturnValue('0x6002' as never)
      const result = await deployEarnProfile(fixture.options)
      expect(result.state).toBe('complete')
      const retained = fixture.read()
      expect(retained.addresses.earnContributionController).toBe(
        verified.addresses.earnContributionController,
      )
      expect(retained.actions['deploy-contribution-controller']).toEqual(
        verified.actions['deploy-contribution-controller'],
      )
      expect(retained.addresses.earnMerkleRewardDistributor).toBeUndefined()
      expect(compiler).not.toHaveBeenCalled()
      fixture.assertNoBroadcast()
    } finally {
      fixture.cleanup()
    }
  })
})

describe('retained factory creation across consumer changes', () => {
  test.each([false, true])(
    'keeps the lifecycle-created factory proof across a mode change (verifier outage: %s)',
    async (outage) => {
      const fixture = pendingSourceDeployment({ retainedRouter: true })
      try {
        const record = structuredClone(fixture.record)
        record.actions['deploy-core']!.transactions = [fixture.creation]
        const source = await fixture.verifySources({
          ...fixture.options,
          client: fixture.chain as never,
          record,
        })
        const verified = { ...record, source: { ...record.source, ...source } }
        publishProfileDeploymentRecord(
          fixture.options.profilePath,
          fixture.options.profile,
          verified,
        )
        fixture.changeRouterMode()
        const compiler = vi.spyOn(ChildProcess, 'execFileSync').mockReturnValue('0x6002' as never)
        const fetch = fixture.dependencies.fetch.getMockImplementation()!
        if (outage)
          fixture.dependencies.fetch.mockResolvedValue(new Response('{}', { status: 503 }))
        expect((await deployEarnProfile(fixture.options)).state).toBe(
          outage ? 'verification-pending' : 'complete',
        )
        expect(
          fixture.verification.mock.calls[0]![0].record.source!.contracts.zoneRouter,
        ).toBeUndefined()
        expect(
          fixture.verification.mock.calls[0]![0].record.source!.contracts.zoneRouterFactory,
        ).toEqual(verified.source.contracts.zoneRouterFactory)
        if (outage) {
          expect(fixture.read().source.contracts.zoneRouterFactory).toEqual(
            verified.source.contracts.zoneRouterFactory,
          )
          rmSync(pendingDeploymentPath(fixture.options.profilePath))
          fixture.dependencies.fetch.mockImplementation(fetch)
          const readSource = fixture.dependencies.readSource.getMockImplementation()!
          fixture.dependencies.readSource.mockImplementation((path) =>
            path.endsWith('/ZoneRouterFactory.sol')
              ? 'today’s different factory source'
              : readSource(path),
          )
          expect((await deployEarnProfile(fixture.options)).state).toBe('complete')
        }
        const retained = fixture.read()
        expect(retained.addresses.zoneRouter).toBe(fixture.nextRouter)
        expect(retained.addresses.zoneRouterFactory).toBe(record.addresses.zoneRouterFactory)
        expect(retained.actions['deploy-zone-router-factory']).toEqual(
          record.actions['deploy-zone-router-factory'],
        )
        expect(retained.source.contracts.zoneRouterFactory).toEqual(
          verified.source.contracts.zoneRouterFactory,
        )
        const published = readFileSync(fixture.recordPath, 'utf8')
        expect((await deployEarnProfile(fixture.options)).state).toBe('complete')
        expect(readFileSync(fixture.recordPath, 'utf8')).toBe(published)
        expect(compiler).not.toHaveBeenCalled()
        fixture.assertNoBroadcast()
      } finally {
        fixture.cleanup()
      }
    },
  )

  test.each([
    'factory source',
    'factory input',
    'factory sender',
    'factory receipt',
    'new router source',
    'action',
    'address',
    'intent',
  ] as const)(
    'rejects changed %s evidence rather than carrying the previous proof',
    async (corruption) => {
      const fixture = pendingSourceDeployment({ retainedRouter: true })
      try {
        const record = structuredClone(fixture.record)
        record.actions['deploy-core']!.transactions = [fixture.creation]
        const source = await fixture.verifySources({
          ...fixture.options,
          client: fixture.chain as never,
          record,
        })
        const verified = { ...record, source: { ...record.source, ...source } }
        publishProfileDeploymentRecord(
          fixture.options.profilePath,
          fixture.options.profile,
          verified,
        )
        if (corruption === 'intent') {
          verified.componentDeploymentIntentHashes.zoneRouterFactory = '0'.repeat(64)
          writeFileSync(fixture.recordPath, JSON.stringify(verified))
        }
        fixture.changeRouterMode()
        const published = readFileSync(fixture.recordPath, 'utf8')
        const compiler = vi.spyOn(ChildProcess, 'execFileSync').mockReturnValue('0x6002' as never)
        if (corruption === 'factory input') fixture.factoryTransaction.input = '0x6000'
        if (corruption === 'factory sender') fixture.factoryTransaction.from = zeroAddress
        if (corruption === 'factory receipt') {
          const receipt = fixture.chain.getTransactionReceipt.getMockImplementation()!
          fixture.chain.getTransactionReceipt.mockImplementation(async (parameters) => ({
            ...(await receipt(parameters)),
            ...(parameters.hash === fixture.factoryTransaction.hash
              ? { contractAddress: zeroAddress }
              : {}),
          }))
        }
        if (corruption === 'factory source' || corruption === 'new router source') {
          const target =
            corruption === 'factory source'
              ? record.addresses.zoneRouterFactory!
              : fixture.nextRouter
          const fetch = fixture.dependencies.fetch.getMockImplementation()!
          fixture.dependencies.fetch.mockImplementation(async (input) => {
            const response = await fetch(input)
            if (!String(input).toLowerCase().includes(target.toLowerCase())) return response
            return Response.json({
              ...((await response.json()) as object),
              sources: { 'src/Changed.sol': { content: 'changed source' } },
            })
          })
        }
        if (corruption === 'action' || corruption === 'address' || corruption === 'intent') {
          const prepare = Reconcile.prepareLifecycleStep
          vi.spyOn(Reconcile, 'prepareLifecycleStep').mockImplementation(async (parameters) => {
            // Re-present the old creation after its declared intent changed; it must be admitted anew.
            if (corruption === 'intent')
              return {
                kind: 'complete',
                pending: {
                  ...loadPendingDeployment(parameters.profilePath, parameters.profile),
                  actions: record.actions,
                  outputs: record.addresses as Record<string, Hex>,
                },
              }
            const result = await prepare(parameters)
            if (result.kind === 'complete') {
              if (corruption === 'address')
                result.pending.outputs.zoneRouterFactory = getAddress(`0x${'f'.repeat(40)}`)
              else
                result.pending.actions['deploy-zone-router-factory'] = {
                  ...result.pending.actions['deploy-zone-router-factory']!,
                  completedAt: '2026-02-01T00:00:00.000Z',
                }
            }
            return result
          })
        }
        await expect(deployEarnProfile(fixture.options)).rejects.toThrow(
          corruption === 'action' || corruption === 'intent'
            ? /unexpected creation input/
            : corruption === 'address' || corruption === 'factory receipt'
              ? /does not prove creation/
              : corruption === 'factory input'
                ? /unexpected creation input/
                : corruption === 'factory sender'
                  ? /expected direct creation/
                  : /source/,
        )
        // A new output is durably pending before source admission; it never acquires the old router's proof.
        if (corruption === 'new router source') {
          expect(fixture.read().source.contractVerification).toBe('pending')
          expect(fixture.read().source.contracts.zoneRouter).toBeUndefined()
          expect(fixture.read().source.contracts.zoneRouterFactory).toEqual(
            verified.source.contracts.zoneRouterFactory,
          )
        } else expect(readFileSync(fixture.recordPath, 'utf8')).toBe(published)
        if (corruption === 'action' || corruption === 'intent')
          expect(compiler).toHaveBeenCalledOnce()
        else expect(compiler).not.toHaveBeenCalled()
        fixture.assertNoBroadcast()
      } finally {
        fixture.cleanup()
      }
    },
  )
})

/** Exercises real record publication, reconciliation, provenance, and source checks over read-only RPC fixtures. */
function pendingSourceDeployment({
  provisionEngine = false,
  retainedController = false,
  retainedRouter = false,
} = {}) {
  const directory = mkdtempSync(join(tmpdir(), 'earn-pending-source-'))
  const address = (suffix: string) => getAddress(`0x${suffix.padStart(40, '0')}`)
  const creation: Hex = `0x${'ab'.repeat(32)}`
  const controllerCreation: Hex = `0x${'ca'.repeat(32)}`
  const distributorCreation: Hex = `0x${'da'.repeat(32)}`
  const factoryCreation: Hex = `0x${'fa'.repeat(32)}`
  const routerCreation: Hex = `0x${'fb'.repeat(32)}`
  const nextRouterCreation: Hex = `0x${'fc'.repeat(32)}`
  const nextRouter = address('b2')
  let routerChanged = false
  const historicalBytecode = '0x6001'
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
    ...(retainedRouter
      ? {
          zoneRouterFactory: address('f0'),
          zoneRouter: address('b1'),
          zoneRouterPortal: address('b0'),
        }
      : {}),
    ...(retainedController
      ? { earnContributionController: address('c0'), earnMerkleRewardDistributor: address('d0') }
      : {}),
  }
  const authored = {
    version: 1,
    id: 'pending-source-test',
    chainId: 4217,
    owner: address('4'),
    ...(retainedRouter
      ? { zoneRouter: { zoneId: 123, ops: ['spend'], spenders: [address('e1')] } }
      : {}),
    ...(retainedController
      ? {
          targetYield: {
            startTimestamp: 1_800_000_000,
            endTimestamp: 1_800_086_400,
            intervalSeconds: 300,
            annualRate: { bps: 500 },
            funding: [{ wallet: address('f'), remainder: true }],
          },
          boostRewards: {
            startTimestamp: 1_800_000_000,
            endTimestamp: 1_800_086_400,
            intervalSeconds: 300,
            targetAnnualRateBps: 500,
            perUserPrincipalCapAssets: '100',
            totalPrincipalCapAssets: '1000',
            treasury: address('e'),
            funding: { wallet: address('f') },
            excludedAddresses: [],
          },
        }
      : {}),
    engine: provisionEngine
      ? { kind: 'erc4626', venue }
      : { kind: 'veda', address: addresses.engine },
  }
  let profile = parseEarnDeploymentProfile(authored, {
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
        keccak256(code(addresses[key as keyof typeof addresses]!)),
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
            id === 'deploy-zone-router-factory'
              ? [factoryCreation]
              : id === 'deploy-zone-router'
                ? [routerCreation]
                : id === 'deploy-contribution-controller'
                  ? [controllerCreation]
                  : id === 'deploy-merkle-distributor'
                    ? [distributorCreation]
                    : id === 'bind-core'
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
  const minedTransaction = {
    hash: controllerCreation,
    from: profile.deployer,
    to: null,
    input:
      `${historicalBytecode}${encodeAbiParameters([{ type: 'address' }, { type: 'address' }], [addresses.earnVault, profile.owner]).slice(2)}` as Hex,
  }
  const factoryTransaction = {
    hash: factoryCreation,
    from: profile.deployer,
    to: null,
    input: historicalBytecode as Hex,
  }
  const routerEvent = getAbiItem({ abi: zoneRouterFactoryAbi, name: 'RouterDeployed' })
  const routerModeData = (hash: Hex) =>
    encodeAbiParameters(
      routerEvent.inputs.filter((input) => !input.indexed),
      [
        {
          zoneId: 123,
          enabledOps: 4,
          earnVault: zeroAddress,
          privateAsset: zeroAddress,
          pool: zeroAddress,
          customerId: zeroHash,
          spenders: [address(hash === nextRouterCreation ? 'e2' : 'e1')],
        },
      ],
    )
  const routerReceipt = (hash: Hex) => ({
    ...receipt,
    transactionHash: hash,
    logs: [
      {
        address: addresses.zoneRouterFactory!,
        removed: false,
        topics: encodeEventTopics({
          abi: zoneRouterFactoryAbi,
          eventName: 'RouterDeployed',
          args: {
            router: hash === nextRouterCreation ? nextRouter : addresses.zoneRouter!,
            modeHash: keccak256(routerModeData(hash)),
          },
        }),
        data: routerModeData(hash),
      },
    ],
  })
  const chain = {
    getTransaction: vi.fn(async ({ hash }: { hash: Hex }) => {
      if (hash === factoryCreation) return factoryTransaction
      if (hash === controllerCreation) return minedTransaction
      const step = deploymentStep('deploy-merkle-distributor')
      if (step.execution !== 'foundry' || !step.source)
        throw new Error('Missing source declaration')
      return {
        ...minedTransaction,
        hash,
        input:
          `${historicalBytecode}${step.source.constructorArgs(profile, addresses as never).slice(2)}` as Hex,
      }
    }),
    getBlock: vi.fn(async () => ({ hash: genesis })),
    getBlockNumber: vi.fn(async () => 10n),
    getLogs: vi.fn(
      async ({ address: target }: { address: string }): Promise<{ transactionHash: Hex }[]> => [
        {
          transactionHash:
            target === addresses.zoneRouterFactory
              ? routerChanged
                ? nextRouterCreation
                : routerCreation
              : target === profile.factories.erc4626Engine
                ? engineCreation
                : creation,
        },
      ],
    ),
    getCode: vi.fn(async ({ address, blockNumber }: { address: string; blockNumber?: bigint }) =>
      blockNumber === 9n ? '0x' : code(address),
    ),
    getTransactionReceipt: vi.fn(async ({ hash }: { hash: Hex }) =>
      hash === factoryCreation
        ? {
            ...receipt,
            transactionHash: hash,
            contractAddress: addresses.zoneRouterFactory,
            logs: [],
          }
        : hash === routerCreation || hash === nextRouterCreation
          ? routerReceipt(hash)
          : hash === controllerCreation || hash === distributorCreation
            ? {
                ...receipt,
                transactionHash: hash,
                contractAddress:
                  hash === controllerCreation
                    ? addresses.earnContributionController
                    : addresses.earnMerkleRewardDistributor,
                logs: [],
              }
            : hash === engineCreation
              ? engineReceipt
              : hash === creation
                ? receipt
                : { ...receipt, status: 'success', transactionHash: hash, blockNumber: 10n },
    ),
    getStorageAt: vi.fn(async () => `0x${'0'.repeat(24)}${vaultImplementation.slice(2)}`),
    readContract: vi.fn(
      async ({
        address: target,
        functionName,
        args,
      }: {
        address: string
        functionName: string
        args?: readonly unknown[]
      }) => {
        if (retainedRouter) {
          const zoneReads: Record<string, unknown> = {
            zones: { zoneId: 123, portal: addresses.zoneRouterPortal },
            zoneFactory: zoneFactoryAddress,
            zoneId: 123,
            messenger: zoneMessengerAddress,
            encryptionKeyCount: 1n,
            sequencerCount: 1n,
            sequencerAt: address('b3'),
          }
          if (functionName in zoneReads) return zoneReads[functionName]
          if (target === addresses.zoneRouterFactory)
            return functionName === 'isRouter'
              ? args?.[0] !== zeroAddress
              : routerChanged
                ? nextRouter
                : addresses.zoneRouter
          if (target === addresses.zoneRouter || target === nextRouter) {
            const routerReads: Record<string, unknown> = {
              enabledOps: 4,
              spenders: profile.zoneRouter!.spenders,
              portal: addresses.zoneRouterPortal,
              allowedZoneId: 123,
              earnVault: zeroAddress,
              earnShare: zeroAddress,
              privateAsset: zeroAddress,
              vaultAsset: zeroAddress,
              pool: zeroAddress,
              customerId: zeroHash,
              privateAssetIsBase: false,
            }
            if (functionName in routerReads) return routerReads[functionName]
          }
        }
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
            : {
                ...addresses,
                decimals: 6,
                vault: venue,
                owner: profile.owner,
                operator: profile.owner,
              }
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
  if (retainedController) {
    contracts.set(
      addresses.earnContributionController!.toLowerCase(),
      'src/rewards/EarnContributionController.sol:EarnContributionController',
    )
    contracts.set(
      addresses.earnMerkleRewardDistributor!.toLowerCase(),
      'src/rewards/EarnMerkleRewardDistributor.sol:EarnMerkleRewardDistributor',
    )
  }
  if (retainedRouter) {
    contracts.set(
      addresses.zoneRouterFactory!.toLowerCase(),
      'src/ZoneRouterFactory.sol:ZoneRouterFactory',
    )
    contracts.set(addresses.zoneRouter!.toLowerCase(), 'src/ZoneRouter.sol:ZoneRouter')
    contracts.set(nextRouter.toLowerCase(), 'src/ZoneRouter.sol:ZoneRouter')
    // Activation owns live access policy, not creation or retained-source admission.
    vi.spyOn(Plan, 'activationActions').mockReturnValue([])
  }
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
          target === addresses.zoneRouterFactory?.toLowerCase()
            ? factoryCreation
            : target === addresses.zoneRouter?.toLowerCase()
              ? routerCreation
              : target === nextRouter.toLowerCase()
                ? nextRouterCreation
                : target === addresses.earnContributionController?.toLowerCase()
                  ? controllerCreation
                  : target === addresses.earnMerkleRewardDistributor?.toLowerCase()
                    ? distributorCreation
                    : provisionEngine && target === addresses.engine.toLowerCase()
                      ? engineCreation
                      : creation,
        creationBytecode: { bytecode: historicalBytecode },
        sources: { [source!]: { content: `canonical:${source}` } },
      })
    }),
    pause: vi.fn(async () => undefined),
    readSource: vi.fn(
      (path: string) =>
        `canonical:${path.replace(directory + '/', '').replace(/^(earn|zone-router)\//, '')}`,
    ),
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
  const verifyRecordedStepCreation = Verify.verifyRecordedStepCreation
  vi.spyOn(Runtime, 'rpcClient').mockReturnValue(chain as never)
  // Binding inspection and preflight have their own tests; reconciliation and creation evidence stay real.
  vi.spyOn(Reconcile, 'preflightEarnDeployment').mockResolvedValue(undefined)
  vi.spyOn(Reconcile, 'verifyEarnDeploymentState').mockResolvedValue({})
  vi.spyOn(Inspection, 'inspectEarnDeployment').mockResolvedValue({})
  vi.spyOn(Provenance, 'captureDeploymentSource').mockImplementation((options) => ({
    ...record.source,
    contractVerification: options.contractVerification,
    contracts: options.contracts ?? {},
    verifierUrl: options.contractVerification === 'verified' ? Verify.tempoVerifierUrl : null,
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
  vi.spyOn(Verify, 'verifyRecordedStepCreation').mockImplementation((parameters) =>
    verifyRecordedStepCreation(parameters, dependencies),
  )
  return {
    options,
    record,
    minedTransaction,
    factoryTransaction,
    nextRouter,
    changeRouterMode() {
      const updated = {
        ...authored,
        zoneRouter: { ...authored.zoneRouter!, spenders: [address('e2')] },
      }
      profile = parseEarnDeploymentProfile(updated, {
        deployer: profile.deployer,
        factories: profile.factories,
      })
      options.profile = profile
      routerChanged = true
      writeFileSync(options.profilePath, JSON.stringify(updated))
    },
    removeBoostRewards() {
      const updated = { ...authored, boostRewards: undefined }
      profile = parseEarnDeploymentProfile(updated, {
        deployer: profile.deployer,
        factories: profile.factories,
      })
      options.profile = profile
      writeFileSync(options.profilePath, JSON.stringify(updated))
    },
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
