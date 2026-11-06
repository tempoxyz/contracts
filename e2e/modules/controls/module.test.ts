import { describe, expect, it } from 'vitest'
import { ContractFunctionRevertedError, encodeErrorResult, getAddress, zeroAddress } from 'viem'
import { earnVaultAbi } from '@tempoxyz/contracts/abis'
import { expectContractRevert } from '../../harness/support/transactions.js'
import { requireControlActors } from './preflight.js'
import { withRecovery } from './recovery.js'
import { migrationProbes } from './migrations.js'

const user = getAddress('0x0000000000000000000000000000000000000a01')
const operator = getAddress('0x0000000000000000000000000000000000000a02')
const outsider = getAddress('0x0000000000000000000000000000000000000a03')
const guardian = getAddress('0x0000000000000000000000000000000000000a04')
const actors = { user, operator, outsider, vaultOperator: operator, guardian }

describe('requireControlActors', () => {
  it('accepts distinct roles, including a disabled guardian', () => {
    expect(() => requireControlActors(actors)).not.toThrow()
    expect(() => requireControlActors({ ...actors, guardian: zeroAddress })).not.toThrow()
  })

  it.each([operator, guardian])(
    'blocks a privileged user %s before running mutations',
    async (user) => {
      const mutations: string[] = []
      await expect(
        (async () => {
          requireControlActors({ ...actors, user: user.toLowerCase() as typeof user })
          mutations.push('fund', 'pause')
        })(),
      ).rejects.toThrow('configure END_USER_PRIVATE_KEY')
      expect(mutations).toEqual([])
    },
  )

  it('requires a recovery operator and an independent temporary guardian', () => {
    expect(() => requireControlActors({ ...actors, vaultOperator: guardian })).toThrow(
      'configured operator',
    )
    expect(() => requireControlActors({ ...actors, outsider: operator })).toThrow('distinct user')
    expect(() => requireControlActors({ ...actors, outsider: user })).toThrow('distinct user')
  })
})

describe('withRecovery', () => {
  it.each(['write', 'readback'])(
    'restores the guardian after an unpause %s failure',
    async (failure) => {
      let currentGuardian = guardian
      let paused = false
      const problem = new Error(`unpause ${failure} failed`)
      const recovery = withRecovery(async () => {
        currentGuardian = outsider
        paused = true
      }, [
        {
          label: 'vault setDepositsPaused(false)',
          async restore() {
            if (failure === 'readback') paused = false
            throw problem
          },
        },
        {
          label: `vault setEmergencyRoles(${guardian}, ${zeroAddress})`,
          async restore() {
            currentGuardian = guardian
          },
        },
      ])
      await expect(recovery).rejects.toThrow(
        'Manual recovery required: vault setDepositsPaused(false)',
      )
      expect(currentGuardian).toBe(guardian)
      expect(paused).toBe(failure === 'write')
    },
  )

  it('preserves the original failure and every failed restoration with actionable labels', async () => {
    const caseError = new Error('authorization regression')
    const pauseError = new Error('unpause RPC failure')
    const roleError = new Error('guardian RPC failure')
    const result = await withRecovery(async () => {
      throw caseError
    }, [
      {
        label: 'chain 1337 vault setDepositsPaused(false)',
        async restore() {
          throw pauseError
        },
      },
      {
        label: 'chain 1337 vault setEmergencyRoles(original, janitor)',
        async restore() {
          throw roleError
        },
      },
    ]).catch((error: unknown) => error)
    expect(result).toBeInstanceOf(AggregateError)
    expect((result as AggregateError).errors).toEqual([caseError, pauseError, roleError])
    expect((result as AggregateError).message).toContain('authorization regression')
    expect((result as AggregateError).message).toContain('setDepositsPaused(false)')
    expect((result as AggregateError).message).toContain('setEmergencyRoles(original, janitor)')
  })

  it('restores unexpected negative mutations and rethrows the original failure', async () => {
    let currentGuardian = guardian
    const error = new Error('unauthorized rotation succeeded')
    await expect(
      withRecovery(async () => {
        currentGuardian = outsider
        throw error
      }, [
        {
          label: 'restore guardian',
          async restore() {
            currentGuardian = guardian
          },
        },
      ]),
    ).rejects.toBe(error)
    expect(currentGuardian).toBe(guardian)
  })
})

describe('migrationProbes', () => {
  it('requires NotOperator, not SameEngine, from an unauthorized migration', () => {
    expect(migrationProbes(1, guardian)).toEqual([
      { actor: 'user', engine: guardian, errorName: 'NotOperator' },
      { actor: 'operator', engine: zeroAddress, errorName: 'ZeroAddress' },
      { actor: 'operator', engine: guardian, errorName: 'SameEngine' },
    ])
  })

  it('rejects SameEngine as authorization evidence and requires the actual NotOperator selector', async () => {
    const probe = migrationProbes(1, guardian)[0]!
    const sameEngine = new ContractFunctionRevertedError({
      abi: earnVaultAbi,
      functionName: 'migrateEngine',
      data: encodeErrorResult({ abi: earnVaultAbi, errorName: 'SameEngine' }),
    })
    await expect(
      expectContractRevert(
        async () => {
          throw sameEngine
        },
        'missing authorization',
        {
          abi: earnVaultAbi,
          errorName: probe.errorName,
        },
      ),
    ).rejects.toBe(sameEngine)
    const notOperator = new ContractFunctionRevertedError({
      abi: earnVaultAbi,
      functionName: 'migrateEngine',
      data: encodeErrorResult({ abi: earnVaultAbi, errorName: 'NotOperator' }),
    })
    await expect(
      expectContractRevert(
        async () => {
          throw notOperator
        },
        'missing authorization',
        {
          abi: earnVaultAbi,
          errorName: probe.errorName,
        },
      ),
    ).resolves.toBeUndefined()
    await expect(
      expectContractRevert(
        async () => {
          throw notOperator
        },
        'missing mode check',
        {
          abi: earnVaultAbi,
          errorName: migrationProbes(0, guardian)[0]!.errorName,
        },
      ),
    ).rejects.toBe(notOperator)
  })

  it('does not claim operator authorization in UserOnly mode', () => {
    expect(migrationProbes(0, guardian)).toEqual([
      { actor: 'user', engine: guardian, errorName: 'OperatorMigrationDisabled' },
      { actor: 'operator', engine: guardian, errorName: 'OperatorMigrationDisabled' },
    ])
    expect(() => migrationProbes(2, guardian)).toThrow('Unknown engine migration mode')
  })
})
