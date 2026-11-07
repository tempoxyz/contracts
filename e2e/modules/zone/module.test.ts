import { describe, expect, it } from 'vitest'
import { requireDistinctPrivateActors } from './module.js'

describe('requireDistinctPrivateActors', () => {
  it('blocks aliased actors before claiming third-party coverage', () => {
    const user = '0x00000000000000000000000000000000000000aa'
    expect(() =>
      requireDistinctPrivateActors(user, '0x00000000000000000000000000000000000000AA'),
    ).toThrow('distinct user and operator')
    expect(() =>
      requireDistinctPrivateActors(user, '0x00000000000000000000000000000000000000bb'),
    ).not.toThrow()
  })
})
