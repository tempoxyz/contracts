import { readdirSync, readFileSync } from 'node:fs'
import { expect, it } from 'vitest'
import { dependencyEnvironment } from './foundry.js'

const foundryRoot = new URL('../../earn/script/local/', import.meta.url)

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
  expect(new Set(reads)).toEqual(new Set(['FixtureScript.sol: vm.envUint("DEPLOYER_PRIVATE_KEY")']))
})

it('dependency builds never inherit signer, RPC, or process injection credentials', () => {
  const environment = {
    PATH: '/tools',
    HOME: '/home/test',
    CARGO_HOME: '/cargo',
    RUSTUP_HOME: '/rustup',
    DEPLOYER_PRIVATE_KEY: 'deployer-secret',
    ZONE_ADMIN_PRIVATE_KEY: 'admin-secret',
    ENGINE_OWNER_PRIVATE_KEY: 'owner-secret',
    TEMPO_RPC_URL: 'https://user:secret@rpc.test',
    NODE_OPTIONS: '--require injected',
    BASH_ENV: '/injected',
    LD_PRELOAD: '/injected',
    CARGO_REGISTRIES_PRIVATE_TOKEN: 'registry-secret',
  }
  expect(dependencyEnvironment(environment)).toEqual({
    PATH: '/tools',
    HOME: '/home/test',
    CARGO_HOME: '/cargo',
    RUSTUP_HOME: '/rustup',
  })
})
