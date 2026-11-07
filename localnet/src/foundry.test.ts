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
    AWS_SESSION_TOKEN: 'cloud-secret',
    GIT_CONFIG_COUNT: '1',
    GIT_CONFIG_KEY_0: 'http.extraHeader',
    GIT_CONFIG_VALUE_0: 'Authorization: secret',
    GIT_SSL_NO_VERIFY: 'true',
    CARGO_HTTP_SSL_VERIFY: 'false',
    FOUNDRY_PROFILE: 'unreviewed',
    FOUNDRY_SOLC: '/unreviewed',
    SOLC_PATH: '/unreviewed',
    RUSTC: '/unreviewed',
    RUSTC_WRAPPER: '/unreviewed',
    RUSTFLAGS: '--cfg unreviewed',
    CARGO_BUILD_RUSTFLAGS: '--cfg unreviewed',
    NODE_EXTRA_CA_CERTS: '/unrelated-node-ca.pem',
  }
  expect(dependencyEnvironment(environment)).toEqual({
    PATH: '/tools',
    HOME: '/home/test',
    CARGO_HOME: '/cargo',
    RUSTUP_HOME: '/rustup',
  })
})

it('preserves only defined proxy and CA settings without normalizing case or empty values', () => {
  const environment = {
    HTTP_PROXY: 'http://upper-http.example:8080',
    HTTPS_PROXY: 'http://upper-https.example:8080',
    ALL_PROXY: 'socks5://upper-all.example:1080',
    NO_PROXY: 'localhost,127.0.0.1,.internal.example',
    http_proxy: 'http://lower-http.example:8081',
    https_proxy: 'http://lower-https.example:8081',
    all_proxy: 'socks5://lower-all.example:1081',
    no_proxy: '',
    SSL_CERT_FILE: '/trust/root.pem',
    SSL_CERT_DIR: '/trust/roots',
    GIT_SSL_CAINFO: '/trust/git.pem',
    GIT_SSL_CAPATH: '/trust/git',
    GIT_PROXY_SSL_CAINFO: '/trust/git-proxy.pem',
    CARGO_HTTP_PROXY: 'http://cargo.example:8080',
    CARGO_HTTP_CAINFO: '/trust/cargo.pem',
    CARGO_HTTP_PROXY_CAINFO: '/trust/cargo-proxy.pem',
  }
  expect(dependencyEnvironment(environment)).toEqual(environment)
  expect(dependencyEnvironment({ HTTPS_PROXY: undefined, https_proxy: '' })).toEqual({
    https_proxy: '',
  })
  expect(dependencyEnvironment({})).toEqual({})
})
