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
  zeroAddress,
  zeroHash,
  type Address,
  type Hex,
} from 'viem'
import { Addresses } from 'viem/tempo'
import { describe, expect, test, vi } from 'vitest'

import {
  deployFactoryReleaseScriptAbi,
  deployRouterReleaseScriptAbi,
  zoneRouterAbi,
} from '../abis/index.js'
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
  releaseSalt,
  routerReleaseKinds,
  updateReleaseRegistry,
  type FactoryReleaseRun,
  type FactoryReleaseDependencies,
  type PredictedContract,
} from './factory-release.js'

const address = (suffix: string) => getAddress(`0x${suffix.padStart(40, '0')}`)
const bytecode = (contract: string) =>
  `0x6080${Buffer.from(contract.split(':')[1]!).toString('hex')}` as Hex
const core = planFactoryRelease('core', 4217)
const hash = (index: number) => `0x${String(index + 1).repeat(64)}` as Hex
const spendMode = { zoneId: 7, enabledOps: 4, settlers: [address('5e771e')] }
const routerParameters = { factory: address('f1'), mode: spendMode }

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

  test('the router releases run from the router project and name no registry entry', () => {
    const factory = planFactoryRelease('zoneRouterFactory', 4217)
    expect(factory).toMatchObject({
      project: 'router',
      script: 'script/deploy/DeployRouterRelease.s.sol:DeployRouterReleaseScript',
      contracts: [
        { name: 'ZoneRouterFactory', contract: 'src/ZoneRouterFactory.sol:ZoneRouterFactory' },
      ],
      forgeArguments: [],
    })
    expect(
      decodeFunctionData({ abi: deployRouterReleaseScriptAbi, data: factory.calldata }),
    ).toEqual({ functionName: 'zoneRouterFactory', args: [4217n] })
    const settler = planFactoryRelease('sendSettler', 42431)
    expect(settler.parameters).toEqual({ pool: zeroAddress, customerId: zeroHash })
    expect(
      decodeFunctionData({ abi: deployRouterReleaseScriptAbi, data: settler.calldata }),
    ).toEqual({ functionName: 'sendSettler', args: [42431n, zeroAddress, zeroHash] })
    const router = planFactoryRelease('zoneRouter', 4217, routerParameters)
    expect(
      decodeFunctionData({ abi: deployRouterReleaseScriptAbi, data: router.calldata }),
    ).toEqual({
      functionName: 'zoneRouter',
      args: [
        4217n,
        routerParameters.factory,
        {
          ...spendMode,
          earnVault: zeroAddress,
          privateAsset: zeroAddress,
          pool: zeroAddress,
          customerId: zeroHash,
        },
      ],
    })
    for (const plan of [factory, settler, router]) {
      expect(plan.project).toBe('router')
      expect(plan.registryKey).toBeUndefined()
    }
    expect(planFactoryRelease('core', 4217).project).toBe('earn')
    expect(planFactoryRelease('erc4626Engine', 4217).project).toBe('earn')
  })
})

describe('release parameters', () => {
  test('kinds without parameters refuse any', () => {
    for (const kind of ['core', 'rewards', 'erc4626Engine', 'zoneRouterFactory']) {
      expect(planFactoryRelease(kind, 4217, {}).parameters).toEqual({})
      expect(() => planFactoryRelease(kind, 4217, { pool: address('1') })).toThrow(
        `The ${kind} release takes no parameters`,
      )
    }
    expect(() => planFactoryRelease('core', 4217, [])).toThrow('parameters must be an object')
  })

  test('a SendSettler converts with a pool and customer ID set together, or not at all', () => {
    const customerId = keccak256(stringToBytes('customer'))
    expect(
      planFactoryRelease('sendSettler', 4217, { pool: address('aa').toLowerCase(), customerId })
        .parameters,
    ).toEqual({ pool: address('aa'), customerId })
    expect(() => planFactoryRelease('sendSettler', 4217, { pool: address('aa') })).toThrow(
      'parameters.pool and parameters.customerId are set together or not at all',
    )
    expect(() =>
      planFactoryRelease('sendSettler', 4217, { pool: zeroAddress, customerId }),
    ).toThrow('parameters.pool must be a nonzero address')
    expect(() =>
      planFactoryRelease('sendSettler', 4217, { pool: address('aa'), customerId: zeroHash }),
    ).toThrow('parameters.customerId must be a nonzero bytes32')
    expect(() => planFactoryRelease('sendSettler', 4217, { owner: address('aa') })).toThrow(
      'parameters.owner is not supported',
    )
  })

  test('a ZoneRouter mode keeps the constructor rules that need no chain state', () => {
    const plan = (mode: Record<string, unknown>, factory: unknown = routerParameters.factory) =>
      planFactoryRelease('zoneRouter', 4217, { factory, mode })
    const earn = { earnVault: address('e1'), privateAsset: address('e2') }
    expect(plan({ zoneId: 3, enabledOps: 3, ...earn }).parameters).toEqual({
      factory: routerParameters.factory,
      mode: {
        zoneId: 3,
        enabledOps: 3,
        ...earn,
        pool: zeroAddress,
        customerId: zeroHash,
        settlers: [],
      },
    })
    expect(() => planFactoryRelease('zoneRouter', 4217, { mode: spendMode })).toThrow(
      'parameters.factory is required',
    )
    expect(() => plan(spendMode, zeroAddress)).toThrow(
      'parameters.factory must be a nonzero address',
    )
    expect(() => plan({ ...spendMode, zoneId: 0 })).toThrow(
      'parameters.mode.zoneId must be a positive',
    )
    expect(() => plan({ ...spendMode, zoneId: 2 ** 32 })).toThrow('must fit uint32')
    expect(() => plan({ ...spendMode, enabledOps: 8 })).toThrow(
      'parameters.mode.enabledOps must combine deposit (1), redeem (2) and spend (4)',
    )
    expect(() => plan({ zoneId: 3, enabledOps: 1, earnVault: address('e1') })).toThrow(
      'parameters.mode.privateAsset must be a nonzero address',
    )
    expect(() => plan({ zoneId: 3, enabledOps: 1, ...earn, pool: address('b0') })).toThrow(
      'parameters.mode.pool and parameters.mode.customerId are set together or not at all',
    )
    expect(() => plan({ ...spendMode, earnVault: address('e1') })).toThrow(
      'parameters.mode.earnVault is not supported without deposit or redeem',
    )
    expect(() => plan({ zoneId: 3, enabledOps: 4 })).toThrow(
      'parameters.mode.settlers is required with spend',
    )
    expect(() => plan({ ...spendMode, settlers: [] })).toThrow('must list at least one settler')
    expect(() => plan({ zoneId: 3, enabledOps: 1, ...earn, settlers: [address('5')] })).toThrow(
      'parameters.mode.settlers is not supported without spend',
    )
    expect(() =>
      plan({ ...spendMode, settlers: [address('5'), address('5').toLowerCase()] }),
    ).toThrow('Duplicate parameters.mode.settlers settler')
    expect(() => plan({ ...spendMode, routeId: 1 })).toThrow(
      'parameters.mode.routeId is not supported',
    )
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

describe('predictRelease for router releases', () => {
  test('a SendSettler is created through the CREATE2 deployer with its settings as arguments', () => {
    const customerId = keccak256(stringToBytes('customer'))
    const [poolless] = predictRelease(planFactoryRelease('sendSettler', 4217), bytecode)
    const [converting] = predictRelease(
      planFactoryRelease('sendSettler', 4217, { pool: address('b0'), customerId }),
      bytecode,
    )
    const args = encodeAbiParameters(parseAbiParameters('address, bytes32'), [
      address('b0'),
      customerId,
    ])
    expect(converting!.constructorArgs).toBe(args)
    expect(converting!.address).toBe(
      getContractAddress({
        opcode: 'CREATE2',
        from: create2Deployer,
        salt: releaseSalt,
        bytecode: concatHex([bytecode('src/SendSettler.sol:SendSettler'), args]),
      }),
    )
    expect(poolless!.constructorArgs).toBe(
      encodeAbiParameters(parseAbiParameters('address, bytes32'), [zeroAddress, zeroHash]),
    )
    expect(poolless!.address).not.toBe(converting!.address)
  })

  test('a ZoneRouter is the CREATE2 address its factory creates for the mode', () => {
    const [router] = predictRelease(
      planFactoryRelease('zoneRouter', 4217, routerParameters),
      bytecode,
    )
    const constructor = zoneRouterAbi.find((item) => item.type === 'constructor')!
    const modeArgs = encodeAbiParameters(constructor.inputs, [
      {
        ...spendMode,
        earnVault: zeroAddress,
        privateAsset: zeroAddress,
        pool: zeroAddress,
        customerId: zeroHash,
      },
    ])
    expect(router).toMatchObject({ name: 'ZoneRouter', contract: 'src/ZoneRouter.sol:ZoneRouter' })
    expect(router!.constructorArgs).toBe(modeArgs)
    // ZoneRouterFactory salts with keccak256(abi.encode(mode)).
    expect(router!.address).toBe(
      getContractAddress({
        opcode: 'CREATE2',
        from: routerParameters.factory,
        salt: keccak256(modeArgs),
        bytecode: concatHex([bytecode('src/ZoneRouter.sol:ZoneRouter'), modeArgs]),
      }),
    )
    expect(router).not.toHaveProperty('creator')
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

describe('createdContracts for a contract created inside a call', () => {
  const plan = planFactoryRelease('zoneRouter', 4217, routerParameters)
  const [router] = predictRelease(plan, bytecode)
  /** Forge's broadcast of `factory.deploy(mode)`: a call that records the router it created. */
  const deployCall = (created = router!.address, initCode: Hex = router!.initCode) => ({
    transactions: [
      {
        transactionType: 'CALL',
        contractName: null,
        contractAddress: routerParameters.factory,
        hash: hash(0),
        transaction: { to: routerParameters.factory, input: '0x1234' },
        additionalContracts: [
          {
            transactionType: 'CREATE2',
            contractName: 'ZoneRouter',
            address: created.toLowerCase(),
            initCode,
          },
        ],
      },
    ],
    receipts: [{ transactionHash: hash(0), status: '0x1' }],
  })

  test('reads the router the factory call created, with that call as its transaction', () => {
    expect(createdContracts(plan, deployCall(), [router!], new Set(), true)).toEqual([
      {
        name: 'ZoneRouter',
        contract: 'src/ZoneRouter.sol:ZoneRouter',
        address: router!.address,
        transaction: hash(0),
        constructorArgs: router!.constructorArgs,
      },
    ])
  })

  test('refuses a router at another address, from other code, or without a receipt', () => {
    expect(() =>
      createdContracts(plan, deployCall(address('6')), [router!], new Set(), true),
    ).toThrow(
      'The zoneRouter release created ZoneRouter at 0x0000000000000000000000000000000000000006, expected ZoneRouter',
    )
    expect(() =>
      createdContracts(plan, deployCall(router!.address, '0x6080'), [router!], new Set(), false),
    ).toThrow('ZoneRouter creation input is not its locally compiled creation code')
    expect(() =>
      createdContracts(
        plan,
        { ...deployCall(), receipts: [{ transactionHash: hash(0), status: '0x0' }] },
        [router!],
        new Set(),
        true,
      ),
    ).toThrow('ZoneRouter creation')
  })

  test('requires nothing created for a router that exists, and refuses a second creation', () => {
    const existing = new Set([router!.address])
    expect(
      createdContracts(plan, { transactions: [] }, [router!], existing, true)[0]!.transaction,
    ).toBeNull()
    expect(() => createdContracts(plan, deployCall(), [router!], existing, true)).toThrow(
      'The zoneRouter release created ZoneRouter, expected nothing',
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

  test('runs a router release from the router project and records its parameters', async () => {
    const plan = planFactoryRelease('zoneRouter', 42431, routerParameters)
    const [router] = predictRelease(plan, bytecode)
    const dependencies = runtime()
    dependencies.readFile.mockImplementation(() =>
      JSON.stringify({
        transactions: [
          {
            transactionType: 'CALL',
            contractAddress: routerParameters.factory,
            hash: hash(0),
            additionalContracts: [
              { transactionType: 'CREATE2', address: router!.address, initCode: router!.initCode },
            ],
          },
        ],
        receipts: [{ transactionHash: hash(0), status: '0x1' }],
      }),
    )
    const result = await deployFactoryRelease(
      options({ network: 'moderato', kind: 'zoneRouter', parameters: routerParameters }),
      dependencies as Partial<FactoryReleaseDependencies>,
    )
    expect(dependencies.preflight.mock.calls[0]![0]).toBe('/repo/router')
    expect(dependencies.creationBytecode.mock.calls[0]!.slice(0, 2)).toEqual([
      '/repo/router',
      'src/ZoneRouter.sol:ZoneRouter',
    ])
    const [forgeArguments, , cwd] = dependencies.forge.mock.calls[0]!
    expect(cwd).toBe('/repo/router')
    expect(forgeArguments.slice(0, 3)).toEqual(['script', plan.script, '--root'])
    expect(forgeArguments[3]).toBe('/repo/router')
    expect(dependencies.readFile).toHaveBeenCalledWith(
      broadcastPath('/repo/router', plan, 42431, true),
    )
    expect(dependencies.removeScriptCache).toHaveBeenCalledWith(
      '/repo/router',
      'DeployRouterRelease.s.sol',
    )
    expect(dependencies.verify.mock.calls[0]![0]).toMatchObject({
      root: '/repo/router',
      address: router!.address,
      contract: 'src/ZoneRouter.sol:ZoneRouter',
      constructorArgs: router!.constructorArgs,
    })
    expect(result).toMatchObject({
      kind: 'zoneRouter',
      parameters: plan.parameters,
      registry: null,
      contracts: [{ name: 'ZoneRouter', transaction: hash(0), match: 'exact_match' }],
    })
    expect(
      await deployFactoryRelease(options(), runtime() as Partial<FactoryReleaseDependencies>),
    ).not.toHaveProperty('parameters')
  })

  test('refuses invalid parameters before running Forge', async () => {
    const dependencies = runtime()
    await expect(
      deployFactoryRelease(
        options({ kind: 'zoneRouterFactory', parameters: { factory: address('f1') } }),
        dependencies as Partial<FactoryReleaseDependencies>,
      ),
    ).rejects.toThrow('The zoneRouterFactory release takes no parameters')
    expect(dependencies.preflight).not.toHaveBeenCalled()
    expect(dependencies.forge).not.toHaveBeenCalled()
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

  test('passes the parameters input through the environment, not the script text', () => {
    expect(workflow).toMatch(/^ {6}parameters:\n(?: {8}.*\n)*? {8}default: '\{\}'$/m)
    expect(workflow).toContain('PARAMETERS: ${{ inputs.parameters }}')
    expect(workflow).toContain('--parameters "$PARAMETERS"')
    expect(workflow.match(/\$\{\{ inputs\.parameters \}\}/g)).toHaveLength(1)
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
    for (const kind of routerReleaseKinds) {
      expect(registryReleaseKinds).not.toContain(kind)
      expect(releaseKindsFor(kind)).toEqual([kind])
    }
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
