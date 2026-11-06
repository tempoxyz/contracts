import { describe, expect, it } from 'vitest'
import { assertPrivateMigrationCredit } from './migration.js'

describe('assertPrivateMigrationCredit', () => {
  const options = {
    privateEarnShares: 93n,
    netAmount: 93n,
    fee: 7n,
    publicDust: 1n,
    mintedEarnShares: 101n,
  }
  it('accounts for actual Portal fees and bounded public dust independently', () => {
    expect(() => assertPrivateMigrationCredit(options)).not.toThrow()
    expect(() => assertPrivateMigrationCredit({ ...options, privateEarnShares: 100n })).toThrow(
      'fully attributable',
    )
  })
  it('rejects partial private delivery, unexplained mint and negative public dust', () => {
    expect(() => assertPrivateMigrationCredit({ ...options, privateEarnShares: 1n })).toThrow(
      'fully attributable',
    )
    expect(() => assertPrivateMigrationCredit({ ...options, mintedEarnShares: 102n })).toThrow(
      'fully attributable',
    )
    expect(() =>
      assertPrivateMigrationCredit({ ...options, publicDust: -1n, mintedEarnShares: 99n }),
    ).toThrow('dust')
  })
})
