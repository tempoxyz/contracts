import { readFileSync } from 'node:fs'
import { decodeFunctionData, getAddress, type Hex } from 'viem'
import { describe, expect, test, vi } from 'vitest'

import { deployFactoryReleaseScriptAbi } from '../abis/index.js'
import { hostedEnvironments } from '../chain/tempo.js'
import {
  broadcastPath,
  createdContracts,
  deployFactoryRelease,
  factoryReleaseKinds,
  planFactoryRelease,
  redactRpcCredentials,
  registryPullRequestBody,
  registryReleaseKinds,
  registryUpdates,
  releaseKindsFor,
  updateReleaseRegistry,
  type FactoryReleaseRun,
  type FactoryReleaseDependencies,
} from './factory-release.js'

const address = (suffix: string) => getAddress(`0x${suffix.padStart(40, '0')}`)
const bytecode = (name: string) => `0x6080${Buffer.from(name).toString('hex')}` as Hex
const args = `0x${'0'.repeat(24)}${'ab'.repeat(20)}`

function broadcastFile(names: string[], status = '0x1') {
  return {
    transactions: names.map((name, index) => ({
      transactionType: 'CREATE',
      contractName: name,
      contractAddress: address(String(index + 1)),
      hash: `0x${String(index + 1).repeat(64)}`,
      transaction: { input: `${bytecode(name)}${index === names.length - 1 ? args.slice(2) : ''}` },
    })),
    receipts: names.map((_, index) => ({
      transactionHash: `0x${String(index + 1).repeat(64)}`,
      status,
    })),
  }
}

describe('planFactoryRelease', () => {
  test('the core release runs earnFactoryRelease for the chain with the large-creation multiplier', () => {
    const plan = planFactoryRelease('core', 4217)
    expect(plan.script).toBe('script/deploy/DeployFactoryRelease.s.sol:DeployFactoryReleaseScript')
    expect(decodeFunctionData({ abi: deployFactoryReleaseScriptAbi, data: plan.calldata })).toEqual(
      {
        functionName: 'earnFactoryRelease',
        args: [4217n],
      },
    )
    expect(plan.contracts.map((contract) => contract.name)).toEqual([
      'EarnVault',
      'EarnFees',
      'EarnFactory',
    ])
    expect(plan.forgeArguments).toEqual(['--gas-estimate-multiplier', '100'])
    expect(plan.registryKey).toBe('earn')
  })

  test('every engine factory release runs its own entry point', () => {
    const plan = planFactoryRelease('erc4626Engine', 42431)
    expect(plan.script).toBe('script/deploy/DeployERC4626Engine.s.sol:DeployERC4626EngineScript')
    expect(plan.contracts).toEqual([
      {
        name: 'ERC4626EngineFactory',
        contract: 'src/engines/ERC4626EngineFactory.sol:ERC4626EngineFactory',
      },
    ])
    expect(plan.registryKey).toBe('erc4626Engine')
  })

  test('refuses an unknown release', () => {
    expect(() => planFactoryRelease('vault', 4217)).toThrow('Unknown factory release vault')
  })
})

describe('createdContracts', () => {
  const plan = planFactoryRelease('core', 4217)

  test('reads each created contract and its constructor arguments', () => {
    const created = createdContracts(
      plan,
      broadcastFile(['EarnVault', 'EarnFees', 'EarnFactory']),
      (contract) => bytecode(contract.split(':')[1]!),
      true,
    )
    expect(created.map((contract) => [contract.name, contract.address])).toEqual([
      ['EarnVault', address('1')],
      ['EarnFees', address('2')],
      ['EarnFactory', address('3')],
    ])
    expect(created[0]!.constructorArgs).toBe('0x')
    expect(created[2]!.constructorArgs).toBe(args)
  })

  test('refuses a run that created other contracts than the release', () => {
    expect(() =>
      createdContracts(
        plan,
        broadcastFile(['EarnVault', 'EarnFees', 'EarnFactory', 'Extra']),
        (contract) => bytecode(contract.split(':')[1]!),
        true,
      ),
    ).toThrow('created EarnVault, EarnFees, EarnFactory, Extra')
  })

  test('refuses a broadcast without a successful receipt', () => {
    expect(() =>
      createdContracts(
        plan,
        broadcastFile(['EarnVault', 'EarnFees', 'EarnFactory'], '0x0'),
        (contract) => bytecode(contract.split(':')[1]!),
        true,
      ),
    ).toThrow('has no successful receipt')
  })

  test('refuses a creation that is not the locally compiled bytecode', () => {
    expect(() =>
      createdContracts(
        plan,
        broadcastFile(['EarnVault', 'EarnFees', 'EarnFactory']),
        () => '0x60806080' as Hex,
        false,
      ),
    ).toThrow('does not start with its locally compiled creation bytecode')
  })
})

describe('deployFactoryRelease', () => {
  function runtime() {
    const files = new Map<string, string>()
    const dependencies = {
      forge: vi.fn(),
      preflight: vi.fn(),
      currentRelease: vi.fn(
        async (_options: unknown): Promise<Record<string, `0x${string}`> | null> => null,
      ),
      removeScriptCache: vi.fn(),
      readFile: vi.fn((path: string) => {
        if (path.endsWith('-latest.json'))
          return JSON.stringify(broadcastFile(['EarnVault', 'EarnFees', 'EarnFactory']))
        const name = /([A-Za-z]+)\.json$/.exec(path)![1]!
        return files.get(path) ?? JSON.stringify({ bytecode: { object: bytecode(name) } })
      }),
      verify: vi.fn(async ({ contract }: { contract: string }) => ({
        kind: 'source' as const,
        name: contract.split(':')[1]!,
        match: 'exact_match' as const,
        sourceInputsHash: '0x' as Hex,
      })),
    }
    return dependencies as typeof dependencies & Partial<FactoryReleaseDependencies>
  }

  test('broadcasts, then source verifies every created contract', async () => {
    const dependencies = runtime()
    const result = await deployFactoryRelease(
      {
        network: 'mainnet',
        kind: 'core',
        broadcast: true,
        root: '/repo/earn',
        environment: {
          PATH: '/bin',
          DEPLOYER_PRIVATE_KEY: '0xkey',
          ZONE_ADMIN_PRIVATE_KEY: '0xno',
        },
      },
      dependencies as Partial<FactoryReleaseDependencies>,
    )
    expect(dependencies.preflight).toHaveBeenCalledOnce()
    const [forgeArguments, forgeEnvironment, cwd] = dependencies.forge.mock.calls[0]!
    expect(forgeArguments).toEqual(expect.arrayContaining(['--broadcast', '--slow', '--rpc-url']))
    expect(forgeArguments[forgeArguments.indexOf('--rpc-url') + 1]).toContain('rpc.tempo.xyz')
    expect(cwd).toBe('/repo/earn')
    // Forge receives only the deployer key from the environment allowlist.
    expect(forgeEnvironment).toEqual({
      PATH: '/bin',
      DEPLOYER_PRIVATE_KEY: '0xkey',
      FOUNDRY_PROFILE: 'deploy',
    })
    expect(dependencies.readFile).toHaveBeenCalledWith(
      broadcastPath('/repo/earn', planFactoryRelease('core', 4217), 4217, true),
    )
    expect(dependencies.verify).toHaveBeenCalledTimes(3)
    expect(dependencies.verify.mock.calls[2]![0]).toMatchObject({
      chainId: 4217,
      address: address('3'),
      contract: 'src/core/EarnFactory.sol:EarnFactory',
      constructorArgs: args,
    })
    expect(result.registry).toEqual({ earn: address('3') })
    expect(result.contracts.every((contract) => contract.match === 'exact_match')).toBe(true)
  })

  test('keeps a deployed contract whose verification fails, with the error', async () => {
    const dependencies = runtime()
    dependencies.verify.mockRejectedValueOnce(
      new Error('verifier timed out calling https://user:secret@rpc.tempo.xyz'),
    )
    const result = await deployFactoryRelease(
      {
        network: 'mainnet',
        kind: 'core',
        broadcast: true,
        root: '/repo/earn',
        environment: {
          DEPLOYER_PRIVATE_KEY: '0xkey',
          TEMPO_RPC_URL: 'https://rpc.tempo.xyz',
          TEMPO_RPC_USERNAME: 'user',
          TEMPO_RPC_PASSWORD: 'secret',
        },
      },
      dependencies as Partial<FactoryReleaseDependencies>,
    )
    expect(result.contracts[0]).toMatchObject({
      name: 'EarnVault',
      address: address('1'),
      match: null,
      verificationError: 'verifier timed out calling ***',
    })
    expect(result.contracts.slice(1).every((contract) => contract.match === 'exact_match')).toBe(
      true,
    )
    expect(result.registry).toEqual({ earn: address('3') })
  })

  test('removes the script sequences that hold the RPC URL, even when Forge fails', async () => {
    const dependencies = runtime()
    dependencies.forge.mockImplementationOnce(() => {
      throw new Error('forge script failed')
    })
    await expect(
      deployFactoryRelease(
        {
          network: 'mainnet',
          kind: 'core',
          broadcast: true,
          root: '/repo/earn',
          environment: { DEPLOYER_PRIVATE_KEY: '0xkey' },
        },
        dependencies as Partial<FactoryReleaseDependencies>,
      ),
    ).rejects.toThrow('forge script failed')
    expect(dependencies.removeScriptCache).toHaveBeenCalledWith(
      '/repo/earn',
      'DeployFactoryRelease.s.sol',
    )
  })

  test('skips a release whose live registry entry already runs this checkout', async () => {
    const dependencies = runtime()
    dependencies.currentRelease.mockResolvedValueOnce({ earn: address('c') })
    const result = await deployFactoryRelease(
      {
        network: 'moderato',
        kind: 'core',
        broadcast: true,
        root: '/repo/earn',
        environment: { DEPLOYER_PRIVATE_KEY: '0xkey' },
      },
      dependencies as Partial<FactoryReleaseDependencies>,
    )
    expect(dependencies.forge).not.toHaveBeenCalled()
    expect(dependencies.verify).not.toHaveBeenCalled()
    expect(result).toMatchObject({
      kind: 'core',
      current: true,
      contracts: [],
      registry: { earn: address('c') },
    })
    expect(dependencies.currentRelease.mock.calls[0]![0]).toMatchObject({ chainId: 42431 })
  })

  test('a dry run simulates without broadcasting or verifying', async () => {
    const dependencies = runtime()
    const result = await deployFactoryRelease(
      {
        network: 'moderato',
        kind: 'core',
        broadcast: false,
        root: '/repo/earn',
        environment: { DEPLOYER_PRIVATE_KEY: '0xkey' },
      },
      dependencies as Partial<FactoryReleaseDependencies>,
    )
    expect(dependencies.forge.mock.calls[0]![0]).not.toContain('--broadcast')
    expect(dependencies.readFile).toHaveBeenCalledWith(
      broadcastPath('/repo/earn', planFactoryRelease('core', 42431), 42431, false),
    )
    expect(broadcastPath('/repo/earn', planFactoryRelease('core', 42431), 42431, false)).toContain(
      '/dry-run/',
    )
    expect(dependencies.verify).not.toHaveBeenCalled()
    expect(result.contracts.every((contract) => contract.match === null)).toBe(true)
  })

  test('refuses an unknown network and a missing deployer key before running Forge', async () => {
    const dependencies = runtime()
    await expect(
      deployFactoryRelease(
        { network: 'devnet', kind: 'core', broadcast: true, root: '/repo/earn', environment: {} },
        dependencies as Partial<FactoryReleaseDependencies>,
      ),
    ).rejects.toThrow('Unknown hosted network devnet')
    await expect(
      deployFactoryRelease(
        { network: 'mainnet', kind: 'core', broadcast: true, root: '/repo/earn', environment: {} },
        dependencies as Partial<FactoryReleaseDependencies>,
      ),
    ).rejects.toThrow('DEPLOYER_PRIVATE_KEY is required')
    expect(dependencies.forge).not.toHaveBeenCalled()
  })
})

describe('factory release workflow', () => {
  const workflow = readFileSync(
    new URL('../../.github/workflows/factory-release.yml', import.meta.url),
    'utf8',
  )
  const options = (input: string) =>
    new RegExp(`^      ${input}:[\\s\\S]*?^        options: \\[([^\\]]*)\\]$`, 'm')
      .exec(workflow)?.[1]
      ?.split(/,\s*/)

  test('offers every hosted network, both, every release, and all', () => {
    expect(options('networks')?.sort()).toEqual(['both', ...Object.keys(hostedEnvironments)].sort())
    expect(options('release')?.sort()).toEqual(['all', ...factoryReleaseKinds].sort())
    expect(workflow).toContain('["moderato","mainnet"]')
  })
})

describe('redactRpcCredentials', () => {
  test('removes the authenticated URL and each credential, raw and encoded', () => {
    const environment = { TEMPO_RPC_USERNAME: 'release', TEMPO_RPC_PASSWORD: 'p@ss:word' }
    const url = 'https://release:p%40ss%3Aword@rpc.tempo.xyz/'
    const text = [
      `error sending request for url (${url})`,
      'user release password p@ss:word encoded p%40ss%3Aword',
    ].join('\n')
    const redacted = redactRpcCredentials(text, url, environment)
    expect(redacted).not.toContain('p@ss:word')
    expect(redacted).not.toContain('p%40ss%3Aword')
    expect(redacted).not.toContain('release')
    expect(redacted).toContain('error sending request for url (***)')
  })

  test('keeps a public URL readable', () => {
    expect(
      redactRpcCredentials('timeout at https://rpc.tempo.xyz', 'https://rpc.tempo.xyz', {}),
    ).toBe('timeout at ***')
  })
})

describe('release selection', () => {
  test('all deploys the core release, then every engine factory the registry names', () => {
    expect(releaseKindsFor('all')).toEqual(['core', 'erc4626Engine'])
    expect(registryReleaseKinds).not.toContain('rewards')
    expect(releaseKindsFor('rewards')).toEqual(['rewards'])
    expect(() => releaseKindsFor('vault')).toThrow('Unknown factory release vault')
  })
})

describe('registry updates', () => {
  const contract = (name: string, suffix: string, match: 'exact_match' | null = 'exact_match') => ({
    name,
    contract: `src/${name}.sol:${name}`,
    address: address(suffix),
    transaction: `0x${suffix.repeat(64)}` as Hex,
    constructorArgs: '0x' as Hex,
    match,
  })
  const run = (network: string, overrides: Partial<FactoryReleaseRun> = {}): FactoryReleaseRun => ({
    network,
    chainId: 1,
    broadcast: true,
    releases: [
      {
        network: network as 'moderato',
        chainId: 1,
        kind: 'core',
        broadcast: true,
        contracts: [
          contract('EarnVault', 'a'),
          contract('EarnFees', 'b'),
          contract('EarnFactory', 'c'),
        ],
        registry: { earn: address('c') },
      },
      {
        network: network as 'moderato',
        chainId: 1,
        kind: 'erc4626Engine',
        broadcast: true,
        contracts: [contract('ERC4626EngineFactory', 'd')],
        registry: { erc4626Engine: address('d') },
      },
    ],
    ...overrides,
  })

  test('an unchanged release needs no registry update', () => {
    const unchanged = run('moderato')
    unchanged.releases[0] = { ...unchanged.releases[0]!, contracts: [], current: true }
    const { updates, skipped } = registryUpdates([unchanged])
    expect(updates.map((update) => update.key)).toEqual(['erc4626Engine'])
    expect(skipped).toEqual([])
  })

  test('records every verified broadcast release on every network', () => {
    const { updates, skipped } = registryUpdates([run('moderato'), run('mainnet')])
    expect(updates.map((update) => [update.network, update.key, update.address])).toEqual([
      ['moderato', 'earn', address('c')],
      ['moderato', 'erc4626Engine', address('d')],
      ['mainnet', 'earn', address('c')],
      ['mainnet', 'erc4626Engine', address('d')],
    ])
    expect(skipped).toEqual([])
  })

  test('skips a release with an unverified contract, a dry run, and a failed release', () => {
    const unverified = run('moderato')
    unverified.releases[0]!.contracts[1] = contract('EarnFees', 'b', null)
    const { updates, skipped } = registryUpdates([
      unverified,
      {
        ...run('mainnet', { broadcast: false }),
        releases: run('mainnet').releases.map((r) => ({ ...r, broadcast: false })),
      },
      { ...run('moderato'), releases: [], failed: { kind: 'core' } },
    ])
    expect(updates.map((update) => update.key)).toEqual(['erc4626Engine'])
    expect(skipped).toEqual([
      { network: 'moderato', kind: 'core', reason: 'not source verified: EarnFees' },
      { network: 'mainnet', kind: 'core', reason: 'dry run' },
      { network: 'mainnet', kind: 'erc4626Engine', reason: 'dry run' },
      { network: 'moderato', kind: 'core', reason: 'failed' },
    ])
  })

  test('rewrites only the named entries of releases.ts', () => {
    const source = readFileSync(new URL('./releases.ts', import.meta.url), 'utf8')
    const updated = updateReleaseRegistry(source, [
      { network: 'moderato', key: 'earn', address: address('c') },
      { network: 'mainnet', key: 'erc4626Engine', address: address('d') },
    ])
    const changed = updated.split('\n').filter((line, index) => line !== source.split('\n')[index])
    expect(changed).toEqual([
      `      erc4626Engine: getAddress('${address('d')}'),`,
      `      earn: getAddress('${address('c')}'),`,
    ])
    expect(updated.indexOf(`erc4626Engine: getAddress('${address('d')}')`)).toBeLessThan(
      updated.indexOf('  moderato: {'),
    )
    expect(() =>
      updateReleaseRegistry(source, [{ network: 'devnet', key: 'earn', address: address('c') }]),
    ).toThrow('releases.ts has no devnet release')
    expect(() =>
      updateReleaseRegistry(source, [{ network: 'moderato', key: 'veda', address: address('c') }]),
    ).toThrow('releases.ts has no moderato.veda entry')
  })

  test('the pull request body lists each recorded contract and each skipped release', () => {
    const runs = [run('moderato'), { ...run('mainnet'), releases: [], failed: { kind: 'core' } }]
    const body = registryPullRequestBody(
      runs,
      registryUpdates(runs),
      'https://github.com/o/r/actions/runs/1',
    )
    expect(body).toContain('[the Factory Release run](https://github.com/o/r/actions/runs/1)')
    expect(body).toContain(`| moderato | core | EarnFactory | \`${address('c')}\` |`)
    expect(body).toContain('- mainnet core: failed')
  })
})
