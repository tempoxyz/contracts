import { readFileSync } from 'node:fs'
import {
  concatHex,
  decodeFunctionData,
  encodeAbiParameters,
  getAddress,
  getContractAddress,
  keccak256,
  parseAbiParameters,
  stringToBytes,
  type Address,
  type Hex,
} from 'viem'
import { Addresses } from 'viem/tempo'
import { describe, expect, test, vi } from 'vitest'

import { deployFactoryReleaseScriptAbi } from '../abis/index.js'
import { hostedEnvironments } from '../chain/tempo.js'
import {
  broadcastPath,
  create2Deployer,
  createdContracts,
  deployFactoryRelease,
  factoryReleaseKinds,
  planFactoryRelease,
  predictRelease,
  redactRpcCredentials,
  registryPullRequestBody,
  registryReleaseKinds,
  registryUpdates,
  releaseKindsFor,
  main,
  releaseSalt,
  updateReleaseRegistry,
  type FactoryReleaseRun,
  type FactoryReleaseDependencies,
  type PredictedContract,
} from './factory-release.js'
import { routerReleaseKinds } from './zone-router-release.js'

const address = (suffix: string) => getAddress(`0x${suffix.padStart(40, '0')}`)
const bytecode = (contract: string) =>
  `0x6080${Buffer.from(contract.split(':')[1]!).toString('hex')}` as Hex
const core = planFactoryRelease('core', 4217)
const hash = (index: number) => `0x${String(index + 1).repeat(64)}` as Hex

/** Forge's broadcast of CREATE2 creations: the deployer call's input is the salt, then the init code. */
function broadcastFile(created: readonly PredictedContract[], status = '0x1') {
  return {
    transactions: created.map((contract, index) => ({
      transactionType: 'CREATE2',
      contractName: contract.name,
      contractAddress: contract.address.toLowerCase(),
      hash: hash(index),
      transaction: { to: create2Deployer, input: concatHex([releaseSalt, contract.initCode]) },
    })),
    receipts: created.map((_, index) => ({ transactionHash: hash(index), status })),
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

  test("plans only Earn's releases, from Earn's project and without parameters", () => {
    for (const kind of factoryReleaseKinds) {
      expect(planFactoryRelease(kind, 4217)).toMatchObject({
        kind,
        project: 'earn',
        parameters: {},
      })
    }
    for (const kind of ['zoneRouterFactory', 'sendSettler', 'zoneRouter']) {
      expect(() => planFactoryRelease(kind, 4217)).toThrow(`Unknown factory release ${kind}`)
    }
  })
})

describe('predictRelease', () => {
  test('creates each contract through the CREATE2 deployer with the release salt', () => {
    // The salt Solidity's DeterministicRelease uses.
    expect(releaseSalt).toBe(keccak256(stringToBytes('tempoxyz/earn shared factory release')))
    expect(create2Deployer).toBe(getAddress('0x4e59b44847b379578588920cA78FbF26c0B4956C'))
    const [vault, fees, factory] = predictRelease(core, bytecode)
    expect(vault!.address).toBe(
      getContractAddress({
        opcode: 'CREATE2',
        from: create2Deployer,
        salt: releaseSalt,
        bytecode: bytecode(vault!.contract),
      }),
    )
    // The factory binds the TIP-20 factory and the implementations predicted before it.
    const factoryArgs = encodeAbiParameters(parseAbiParameters('address, address, address'), [
      Addresses.tip20Factory,
      vault!.address,
      fees!.address,
    ])
    expect(factory!.constructorArgs).toBe(factoryArgs)
    expect(factory!.initCode).toBe(concatHex([bytecode(factory!.contract), factoryArgs]))
    expect(factory!.address).toBe(
      getContractAddress({
        opcode: 'CREATE2',
        from: create2Deployer,
        salt: releaseSalt,
        bytecode: factory!.initCode,
      }),
    )
  })
})

describe('createdContracts', () => {
  const predicted = predictRelease(core, bytecode)

  test('reads each created contract at its deterministic address', () => {
    const created = createdContracts(core, broadcastFile(predicted), predicted, new Set(), true)
    expect(
      created.map((contract) => [contract.name, contract.address, contract.transaction]),
    ).toEqual(predicted.map((contract, index) => [contract.name, contract.address, hash(index)]))
    expect(created[2]!.constructorArgs).toBe(predicted[2]!.constructorArgs)
  })

  test('keeps contracts that already existed and requires only the rest to be created', () => {
    const existing = new Set<Address>([predicted[0]!.address, predicted[1]!.address])
    const created = createdContracts(
      core,
      broadcastFile([predicted[2]!]),
      predicted,
      existing,
      true,
    )
    expect(created.map((contract) => contract.transaction)).toEqual([null, null, hash(0)])
    expect(() =>
      createdContracts(core, broadcastFile(predicted), predicted, existing, true),
    ).toThrow('created EarnFactory, EarnFees, EarnVault, expected EarnFactory')
  })

  test('refuses a creation away from its deterministic address', () => {
    const file = broadcastFile(predicted)
    file.transactions[1]!.contractAddress = address('5')
    expect(() => createdContracts(core, file, predicted, new Set(), true)).toThrow(
      'The core release created EarnFactory, EarnFees at 0x0000000000000000000000000000000000000005, EarnVault, expected EarnFactory, EarnFees, EarnVault',
    )
  })

  test('refuses a broadcast without a successful receipt', () => {
    expect(() =>
      createdContracts(core, broadcastFile(predicted, '0x0'), predicted, new Set(), true),
    ).toThrow('has no successful receipt')
  })

  test('refuses a creation that is not the locally compiled code', () => {
    const file = broadcastFile(predicted)
    file.transactions[0]!.transaction.input = concatHex([releaseSalt, '0x60806080'])
    expect(() => createdContracts(core, file, predicted, new Set(), false)).toThrow(
      'EarnVault creation input is not its locally compiled creation code',
    )
  })
})

describe('deployFactoryRelease', () => {
  const predicted = predictRelease(planFactoryRelease('core', 4217), bytecode)

  function runtime(existing: readonly Address[] = []) {
    const dependencies = {
      forge: vi.fn(),
      preflight: vi.fn(),
      removeScriptCache: vi.fn(),
      creationBytecode: vi.fn((_root: string, contract: string) => bytecode(contract)),
      existingCode: vi.fn(
        async (_rpc: unknown, _addresses: readonly Address[]) => new Set(existing),
      ),
      readFile: vi.fn((_path: string) =>
        JSON.stringify(
          broadcastFile(predicted.filter((contract) => !existing.includes(contract.address))),
        ),
      ),
      verify: vi.fn(async ({ contract }: { contract: string }) => ({
        kind: 'source' as const,
        name: contract.split(':')[1]!,
        match: 'exact_match' as const,
        sourceInputsHash: '0x' as Hex,
      })),
    }
    return dependencies
  }
  const options = (overrides: Partial<Parameters<typeof deployFactoryRelease>[0]> = {}) => ({
    network: 'mainnet',
    kind: 'core',
    broadcast: true,
    root: '/repo/earn',
    environment: { DEPLOYER_PRIVATE_KEY: '0xkey' },
    ...overrides,
  })

  test('broadcasts the missing contracts, then source verifies every one', async () => {
    const dependencies = runtime()
    const result = await deployFactoryRelease(
      options({
        environment: {
          PATH: '/bin',
          DEPLOYER_PRIVATE_KEY: '0xkey',
          ZONE_ADMIN_PRIVATE_KEY: '0xno',
        },
      }),
      dependencies as Partial<FactoryReleaseDependencies>,
    )
    expect(dependencies.preflight).toHaveBeenCalledOnce()
    expect(dependencies.existingCode.mock.calls[0]![1]).toEqual(
      predicted.map((contract) => contract.address),
    )
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
      address: predicted[2]!.address,
      contract: 'src/core/EarnFactory.sol:EarnFactory',
      constructorArgs: predicted[2]!.constructorArgs,
    })
    expect(result.current).toBeUndefined()
    expect(result.registry).toEqual({ earn: predicted[2]!.address })
    expect(result.contracts.every((contract) => contract.match === 'exact_match')).toBe(true)
  })

  test('reconciles a release that already exists without running Forge, and still verifies it', async () => {
    const dependencies = runtime(predicted.map((contract) => contract.address))
    const result = await deployFactoryRelease(
      options({ network: 'moderato' }),
      dependencies as Partial<FactoryReleaseDependencies>,
    )
    expect(dependencies.forge).not.toHaveBeenCalled()
    expect(dependencies.removeScriptCache).not.toHaveBeenCalled()
    expect(dependencies.verify).toHaveBeenCalledTimes(3)
    expect(result).toMatchObject({ current: true, registry: { earn: predicted[2]!.address } })
    expect(result.contracts.map((contract) => contract.transaction)).toEqual([null, null, null])
  })

  test('creates only what a partly deployed release is missing', async () => {
    const dependencies = runtime([predicted[0]!.address])
    const result = await deployFactoryRelease(
      options(),
      dependencies as Partial<FactoryReleaseDependencies>,
    )
    expect(dependencies.forge).toHaveBeenCalledOnce()
    expect(result.current).toBeUndefined()
    expect(result.contracts.map((contract) => contract.transaction)).toEqual([
      null,
      hash(0),
      hash(1),
    ])
  })

  test('keeps a deployed contract whose verification fails, with the error', async () => {
    const dependencies = runtime()
    dependencies.verify.mockRejectedValueOnce(
      new Error('verifier timed out calling https://user:secret@rpc.tempo.xyz'),
    )
    const result = await deployFactoryRelease(
      options({
        environment: {
          DEPLOYER_PRIVATE_KEY: '0xkey',
          TEMPO_RPC_URL: 'https://rpc.tempo.xyz',
          TEMPO_RPC_USERNAME: 'user',
          TEMPO_RPC_PASSWORD: 'secret',
        },
      }),
      dependencies as Partial<FactoryReleaseDependencies>,
    )
    expect(result.contracts[0]).toMatchObject({
      name: 'EarnVault',
      address: predicted[0]!.address,
      match: null,
      verificationError: 'verifier timed out calling ***',
    })
    expect(result.contracts.slice(1).every((contract) => contract.match === 'exact_match')).toBe(
      true,
    )
  })

  test('removes the script sequences that hold the RPC URL, even when Forge fails', async () => {
    const dependencies = runtime()
    dependencies.forge.mockImplementationOnce(() => {
      throw new Error('forge script failed')
    })
    await expect(
      deployFactoryRelease(options(), dependencies as Partial<FactoryReleaseDependencies>),
    ).rejects.toThrow('forge script failed')
    expect(dependencies.removeScriptCache).toHaveBeenCalledWith(
      '/repo/earn',
      'DeployFactoryRelease.s.sol',
    )
  })

  test('a dry run simulates without broadcasting or verifying', async () => {
    const dependencies = runtime()
    const result = await deployFactoryRelease(
      options({ network: 'moderato', broadcast: false }),
      dependencies as Partial<FactoryReleaseDependencies>,
    )
    expect(dependencies.forge.mock.calls[0]![0]).not.toContain('--broadcast')
    expect(dependencies.readFile).toHaveBeenCalledWith(
      broadcastPath('/repo/earn', planFactoryRelease('core', 42431), 42431, false),
    )
    expect(dependencies.verify).not.toHaveBeenCalled()
    expect(result.contracts.every((contract) => contract.match === null)).toBe(true)
  })

  test('refuses an unknown network and a missing deployer key before running Forge', async () => {
    const dependencies = runtime()
    await expect(
      deployFactoryRelease(
        options({ network: 'devnet', environment: {} }),
        dependencies as Partial<FactoryReleaseDependencies>,
      ),
    ).rejects.toThrow('Unknown hosted network devnet')
    await expect(
      deployFactoryRelease(
        options({ environment: {} }),
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

  test("releases only Earn's contracts: no parameters and nothing from the router project", () => {
    expect(workflow).not.toMatch(/^ {6}parameters:/m)
    expect(workflow).not.toContain('--parameters')
    expect(workflow).not.toContain('router')
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

  test('refuses the router releases, pointing to their own CLI', () => {
    for (const kind of routerReleaseKinds) {
      expect(() => releaseKindsFor(kind)).toThrow(
        `Unknown factory release ${kind}; expected all or one of ${factoryReleaseKinds.join(', ')} (Zone router contracts release with pnpm zone-router-release)`,
      )
    }
  })
})

describe('factory release CLI', () => {
  test('refuses a router release and parameters before deploying anything', async () => {
    for (const kind of routerReleaseKinds) {
      await expect(main(['moderato', kind], '/nonexistent/earn')).rejects.toThrow(
        'Zone router contracts release with pnpm zone-router-release',
      )
    }
    await expect(
      main(['moderato', 'core', '--parameters', '{}'], '/nonexistent/earn'),
    ).rejects.toThrow("Unknown option '--parameters'")
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

  test('records a verified release that already existed', () => {
    const existing = run('moderato')
    existing.releases[0] = { ...existing.releases[0]!, current: true }
    const { updates, skipped } = registryUpdates([existing])
    expect(updates.map((update) => update.key)).toEqual(['earn', 'erc4626Engine'])
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
