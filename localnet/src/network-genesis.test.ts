import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'

import * as Config from './config.js'
import { parseGenesis } from './network.js'

const runtime = JSON.parse(
  readFileSync(new URL('../fixtures/tip1091-runtime.json', import.meta.url), 'utf8'),
)
const alloc = {
  [Config.address.zonePortalImplementation.toLowerCase()]: { code: runtime.zonePortal },
  [Config.address.zoneMessenger.toLowerCase()]: { code: runtime.zoneMessenger },
  [Config.address.zoneVerifier.toLowerCase()]: { code: runtime.verifier },
}

describe('parseGenesis', () => {
  it('preserves matching genesis entries before any local override', () => {
    const genesis = { alloc, config: { chainId: 1337 } }
    expect(parseGenesis(JSON.stringify(genesis))).toEqual(genesis)
  })

  for (const [name, address] of [
    ['Portal', Config.address.zonePortalImplementation],
    ['Messenger', Config.address.zoneMessenger],
    ['Verifier', Config.address.zoneVerifier],
  ] as const)
    it.each([undefined, '0x', '0x6000'])(
      `rejects ${name} drift in the original dump (%s) before applying fixture bytes`,
      (code) => {
        const genesis = {
          alloc: { ...alloc, [address.toLowerCase()]: code === undefined ? undefined : { code } },
        }
        expect(() => parseGenesis(JSON.stringify(genesis))).toThrow(
          `${name} dumped genesis bytecode differs from the locked runtime`,
        )
      },
    )
})
