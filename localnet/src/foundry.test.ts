import { readdirSync, readFileSync } from 'node:fs'
import { expect, it } from 'vitest'

const foundryRoot = new URL('../../earn/localnet/', import.meta.url)

// `run` passes Forge only the deployer key, so a fixture script must take every other input as
// typed calldata: any other environment read would see nothing.
it('fixture scripts read only the deployer key from the environment', () => {
  const reads = readdirSync(foundryRoot, { recursive: true, encoding: 'utf8' })
    .filter((file) => file.endsWith('.sol'))
    .flatMap((file) =>
      [...readFileSync(new URL(file, foundryRoot), 'utf8').matchAll(/vm\.env\w*(\([^)]*\))?/g)].map(
        ([read]) => `${file}: ${read}`,
      ),
    )
  expect(new Set(reads)).toEqual(
    new Set(['script/FixtureScript.sol: vm.envUint("DEPLOYER_PRIVATE_KEY")']),
  )
})
