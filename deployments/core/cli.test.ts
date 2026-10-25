import { describe, expect, test } from 'vitest'

import { main } from './cli.js'

describe('earn CLI', () => {
  // An unset shell variable must fail instead of silently defaulting the receiver to the depositor.
  test('rejects an empty option value', async () => {
    await expect(
      main(['deposit', 'profile.json', '--assets', '1', '--receiver', ''], console, '/'),
    ).rejects.toThrow('--receiver requires a value')
    await expect(
      main(['access', '--', '--earn-file=', 'status', `0x${'1'.repeat(40)}`], console, '/'),
    ).rejects.toThrow('--earn-file requires a value')
  })

  test('accepts --skip-zone only on verify', async () => {
    await expect(main(['deploy', 'profile.json', '--skip-zone'], console, '/')).rejects.toThrow(
      '--skip-zone is supported only by verify',
    )
  })
})
