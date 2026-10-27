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

  test('offers every hosted network and every release', () => {
    expect(options('network')?.sort()).toEqual(Object.keys(hostedEnvironments).sort())
    expect(options('release')?.sort()).toEqual([...factoryReleaseKinds].sort())
  })
})
