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
import { describe, expect, test, vi } from 'vitest'

import { deployRouterReleaseScriptAbi, zoneRouterAbi } from '../abis/index.js'
import { hostedEnvironments } from '../chain/tempo.js'
import {
  broadcastPath,
  create2Deployer,
  createdContracts,
  factoryReleaseKinds,
  predictRelease,
  releaseSalt,
  type FactoryReleaseDependencies,
} from './factory-release.js'
import {
  deployRouterRelease,
  main,
  planRouterRelease,
  routerReleaseKindFor,
  routerReleaseKinds,
} from './zone-router-release.js'

const address = (suffix: string) => getAddress(`0x${suffix.padStart(40, '0')}`)
const bytecode = (contract: string) =>
  `0x6080${Buffer.from(contract.split(':')[1]!).toString('hex')}` as Hex
const hash = (index: number) => `0x${String(index + 1).repeat(64)}` as Hex
const spendMode = { zoneId: 7, enabledOps: 4, settlers: [address('5e771e')] }
const routerParameters = { factory: address('f1'), mode: spendMode }
const spenderId = keccak256(stringToBytes('bridge.card-program'))
const bridgeParameters = { factory: address('b7'), spenderId }

describe('planRouterRelease', () => {
  test('the router releases run from the zone-router project and name no registry entry', () => {
    const factory = planRouterRelease('zoneRouterFactory', 4217)
    expect(factory).toMatchObject({
      project: 'zone-router',
      script: 'script/deploy/DeployRouterRelease.s.sol:DeployRouterReleaseScript',
      contracts: [
        { name: 'ZoneRouterFactory', contract: 'src/ZoneRouterFactory.sol:ZoneRouterFactory' },
      ],
      forgeArguments: [],
    })
    expect(
      decodeFunctionData({ abi: deployRouterReleaseScriptAbi, data: factory.calldata }),
    ).toEqual({ functionName: 'zoneRouterFactory', args: [4217n] })
    const settler = planRouterRelease('sendSettler', 42431)
    expect(settler.parameters).toEqual({
      vault: zeroAddress,
      pool: zeroAddress,
      customerId: zeroHash,
    })
    expect(
      decodeFunctionData({ abi: deployRouterReleaseScriptAbi, data: settler.calldata }),
    ).toEqual({ functionName: 'sendSettler', args: [42431n, zeroAddress, zeroAddress, zeroHash] })
    const bridgeSettler = planRouterRelease('bridgeSettler', 42431, bridgeParameters)
    expect(bridgeSettler.parameters).toEqual(bridgeParameters)
    expect(bridgeSettler.contracts).toMatchObject([
      { name: 'BridgeSettler', contract: 'src/settlers/BridgeSettler.sol:BridgeSettler' },
    ])
    expect(
      decodeFunctionData({ abi: deployRouterReleaseScriptAbi, data: bridgeSettler.calldata }),
    ).toEqual({
      functionName: 'bridgeSettler',
      args: [42431n, bridgeParameters.factory, spenderId],
    })
    const router = planRouterRelease('zoneRouter', 4217, routerParameters)
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
    for (const plan of [factory, settler, bridgeSettler, router]) {
      expect(plan.project).toBe('zone-router')
      expect(plan.registryKey).toBeUndefined()
    }
  })

  test("refuses Earn's factory releases, pointing to their own CLI", () => {
    for (const kind of ['all', ...factoryReleaseKinds]) {
      expect(() => planRouterRelease(kind, 4217)).toThrow(
        `Unknown router release ${kind}; expected one of zoneRouterFactory, sendSettler, bridgeSettler, zoneRouter (Earn's factory releases run with pnpm factory-release)`,
      )
      expect(() => routerReleaseKindFor(kind)).toThrow('pnpm factory-release')
    }
    for (const kind of routerReleaseKinds) expect(routerReleaseKindFor(kind)).toBe(kind)
  })
})

describe('release parameters', () => {
  test('the ZoneRouterFactory refuses any', () => {
    expect(planRouterRelease('zoneRouterFactory', 4217, {}).parameters).toEqual({})
    expect(() => planRouterRelease('zoneRouterFactory', 4217, { pool: address('1') })).toThrow(
      'The zoneRouterFactory release takes no parameters',
    )
    expect(() => planRouterRelease('zoneRouterFactory', 4217, [])).toThrow(
      'parameters must be an object',
    )
  })

  test('a SendSettler converts with a vault, pool and customer ID set together, or not at all', () => {
    const customerId = keccak256(stringToBytes('customer'))
    const binding = { vault: address('ab'), pool: address('aa'), customerId }
    expect(
      planRouterRelease('sendSettler', 4217, {
        ...binding,
        vault: address('ab').toLowerCase(),
        pool: address('aa').toLowerCase(),
      }).parameters,
    ).toEqual(binding)
    for (const key of ['vault', 'pool', 'customerId'] as const) {
      const { [key]: _, ...partial } = binding
      expect(() => planRouterRelease('sendSettler', 4217, partial)).toThrow(
        'parameters.vault, parameters.pool and parameters.customerId are set together or not at all',
      )
    }
    expect(() =>
      planRouterRelease('sendSettler', 4217, { ...binding, vault: zeroAddress }),
    ).toThrow('parameters.vault must be a nonzero address')
    expect(() => planRouterRelease('sendSettler', 4217, { ...binding, pool: zeroAddress })).toThrow(
      'parameters.pool must be a nonzero address',
    )
    expect(() =>
      planRouterRelease('sendSettler', 4217, { ...binding, customerId: zeroHash }),
    ).toThrow('parameters.customerId must be a nonzero bytes32')
    expect(() => planRouterRelease('sendSettler', 4217, { owner: address('aa') })).toThrow(
      'parameters.owner is not supported',
    )
  })

  test('a BridgeSettler takes exactly a nonzero factory and spender ID', () => {
    expect(
      planRouterRelease('bridgeSettler', 4217, {
        factory: bridgeParameters.factory.toLowerCase(),
        spenderId,
      }).parameters,
    ).toEqual(bridgeParameters)
    expect(() => planRouterRelease('bridgeSettler', 4217, {})).toThrow(
      'parameters.factory is required',
    )
    expect(() => planRouterRelease('bridgeSettler', 4217, { factory: address('b7') })).toThrow(
      'parameters.spenderId is required',
    )
    expect(() =>
      planRouterRelease('bridgeSettler', 4217, { ...bridgeParameters, factory: zeroAddress }),
    ).toThrow('parameters.factory must be a nonzero address')
    expect(() =>
      planRouterRelease('bridgeSettler', 4217, { ...bridgeParameters, spenderId: zeroHash }),
    ).toThrow('parameters.spenderId must be a nonzero bytes32')
    expect(() =>
      planRouterRelease('bridgeSettler', 4217, { ...bridgeParameters, spenderId: '0x1234' }),
    ).toThrow('parameters.spenderId must be a nonzero bytes32')
    expect(() =>
      planRouterRelease('bridgeSettler', 4217, { ...bridgeParameters, zoneId: 7 }),
    ).toThrow('parameters.zoneId is not supported')
  })

  test('a ZoneRouter mode keeps the constructor rules that need no chain state', () => {
    const plan = (mode: Record<string, unknown>, factory: unknown = routerParameters.factory) =>
      planRouterRelease('zoneRouter', 4217, { factory, mode })
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
    expect(() => planRouterRelease('zoneRouter', 4217, { mode: spendMode })).toThrow(
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

describe('predictRelease for router releases', () => {
  test('a SendSettler is created through the CREATE2 deployer with its settings as arguments', () => {
    const customerId = keccak256(stringToBytes('customer'))
    const [poolless] = predictRelease(planRouterRelease('sendSettler', 4217), bytecode)
    const [converting] = predictRelease(
      planRouterRelease('sendSettler', 4217, {
        vault: address('b1'),
        pool: address('b0'),
        customerId,
      }),
      bytecode,
    )
    const args = encodeAbiParameters(parseAbiParameters('address, address, bytes32'), [
      address('b1'),
      address('b0'),
      customerId,
    ])
    expect(converting!.constructorArgs).toBe(args)
    expect(converting!.address).toBe(
      getContractAddress({
        opcode: 'CREATE2',
        from: create2Deployer,
        salt: releaseSalt,
        bytecode: concatHex([bytecode('src/settlers/SendSettler.sol:SendSettler'), args]),
      }),
    )
    expect(poolless!.constructorArgs).toBe(
      encodeAbiParameters(parseAbiParameters('address, address, bytes32'), [
        zeroAddress,
        zeroAddress,
        zeroHash,
      ]),
    )
    expect(poolless!.address).not.toBe(converting!.address)
  })

  test('a BridgeSettler is created through the CREATE2 deployer with its program as arguments', () => {
    const [settler] = predictRelease(
      planRouterRelease('bridgeSettler', 4217, bridgeParameters),
      bytecode,
    )
    const args = encodeAbiParameters(parseAbiParameters('address, bytes32'), [
      bridgeParameters.factory,
      spenderId,
    ])
    expect(settler).toMatchObject({
      name: 'BridgeSettler',
      contract: 'src/settlers/BridgeSettler.sol:BridgeSettler',
    })
    expect(settler!.constructorArgs).toBe(args)
    expect(settler!.address).toBe(
      getContractAddress({
        opcode: 'CREATE2',
        from: create2Deployer,
        salt: releaseSalt,
        bytecode: concatHex([bytecode('src/settlers/BridgeSettler.sol:BridgeSettler'), args]),
      }),
    )
    const [other] = predictRelease(
      planRouterRelease('bridgeSettler', 4217, {
        ...bridgeParameters,
        spenderId: keccak256(stringToBytes('other')),
      }),
      bytecode,
    )
    expect(other!.address).not.toBe(settler!.address)
  })

  test('a ZoneRouter is the CREATE2 address its factory creates for the mode', () => {
    const [router] = predictRelease(
      planRouterRelease('zoneRouter', 4217, routerParameters),
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

describe('createdContracts for a contract created inside a call', () => {
  const plan = planRouterRelease('zoneRouter', 4217, routerParameters)
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

describe('deployRouterRelease', () => {
  function runtime(existing: readonly Address[] = []) {
    return {
      forge: vi.fn(),
      preflight: vi.fn(),
      removeScriptCache: vi.fn(),
      creationBytecode: vi.fn((_root: string, contract: string) => bytecode(contract)),
      existingCode: vi.fn(
        async (_rpc: unknown, _addresses: readonly Address[]) => new Set(existing),
      ),
      readFile: vi.fn((_path: string) => JSON.stringify({ transactions: [] })),
      verify: vi.fn(async ({ contract }: { contract: string }) => ({
        kind: 'source' as const,
        name: contract.split(':')[1]!,
        match: 'exact_match' as const,
        sourceInputsHash: '0x' as Hex,
      })),
    }
  }
  const options = (overrides: Partial<Parameters<typeof deployRouterRelease>[0]> = {}) => ({
    network: 'mainnet',
    kind: 'zoneRouterFactory',
    broadcast: true,
    root: '/repo/earn',
    environment: { DEPLOYER_PRIVATE_KEY: '0xkey' },
    ...overrides,
  })

  test('runs a Zone router release from the zone-router project and records its parameters', async () => {
    const plan = planRouterRelease('zoneRouter', 42431, routerParameters)
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
    const result = await deployRouterRelease(
      options({ network: 'moderato', kind: 'zoneRouter', parameters: routerParameters }),
      dependencies as Partial<FactoryReleaseDependencies>,
    )
    expect(dependencies.preflight.mock.calls[0]![0]).toBe('/repo/zone-router')
    expect(dependencies.creationBytecode.mock.calls[0]!.slice(0, 2)).toEqual([
      '/repo/zone-router',
      'src/ZoneRouter.sol:ZoneRouter',
    ])
    const [forgeArguments, , cwd] = dependencies.forge.mock.calls[0]!
    expect(cwd).toBe('/repo/zone-router')
    expect(forgeArguments.slice(0, 3)).toEqual(['script', plan.script, '--root'])
    expect(forgeArguments[3]).toBe('/repo/zone-router')
    expect(dependencies.readFile).toHaveBeenCalledWith(
      broadcastPath('/repo/zone-router', plan, 42431, true),
    )
    expect(dependencies.removeScriptCache).toHaveBeenCalledWith(
      '/repo/zone-router',
      'DeployRouterRelease.s.sol',
    )
    expect(dependencies.verify.mock.calls[0]![0]).toMatchObject({
      root: '/repo/zone-router',
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
    const [factory] = predictRelease(planRouterRelease('zoneRouterFactory', 42431), bytecode)
    const current = runtime([factory!.address])
    const existing = await deployRouterRelease(
      options({ network: 'moderato', kind: 'zoneRouterFactory' }),
      current as Partial<FactoryReleaseDependencies>,
    )
    expect(current.forge).not.toHaveBeenCalled()
    expect(existing).toMatchObject({ kind: 'zoneRouterFactory', current: true, registry: null })
    expect(existing).not.toHaveProperty('parameters')
  })

  test('refuses invalid parameters before running Forge', async () => {
    const dependencies = runtime()
    await expect(
      deployRouterRelease(
        options({ kind: 'zoneRouterFactory', parameters: { factory: address('f1') } }),
        dependencies as Partial<FactoryReleaseDependencies>,
      ),
    ).rejects.toThrow('The zoneRouterFactory release takes no parameters')
    expect(dependencies.preflight).not.toHaveBeenCalled()
    expect(dependencies.forge).not.toHaveBeenCalled()
  })
})

describe('router release workflow', () => {
  const workflow = readFileSync(
    new URL('../../.github/workflows/zone-router-release.yml', import.meta.url),
    'utf8',
  )
  const options = (input: string) =>
    new RegExp(`^      ${input}:[\\s\\S]*?^        options: \\[([^\\]]*)\\]$`, 'm')
      .exec(workflow)?.[1]
      ?.split(/,\s*/)

  test('offers every hosted network, both, and every router release, without all', () => {
    expect(options('network')?.sort()).toEqual(['both', ...Object.keys(hostedEnvironments)].sort())
    expect(options('release')).toEqual([...routerReleaseKinds])
    expect(workflow).toContain('bridgeSettler {"factory", "spenderId"}')
    expect(workflow).toContain('["moderato","mainnet"]')
    expect(workflow).toContain('environment: factory-release-${{ matrix.network }}')
  })

  test('passes the parameters input through the environment, not the script text', () => {
    expect(workflow).toMatch(/^ {6}parameters:\n(?: {8}.*\n)*? {8}default: '\{\}'$/m)
    expect(workflow).toContain('PARAMETERS: ${{ inputs.parameters }}')
    expect(workflow).toContain('pnpm zone-router-release')
    expect(workflow).toContain('--parameters "$PARAMETERS"')
    expect(workflow.match(/\$\{\{ inputs\.parameters \}\}/g)).toHaveLength(1)
  })
})

describe('router release CLI', () => {
  test("refuses Earn's factory releases and invalid parameters before deploying anything", async () => {
    for (const kind of ['all', ...factoryReleaseKinds]) {
      await expect(main(['moderato', kind], '/nonexistent/earn')).rejects.toThrow(
        "Earn's factory releases run with pnpm factory-release",
      )
    }
    await expect(
      main(['moderato', 'zoneRouter', '--parameters', 'not json'], '/nonexistent/earn'),
    ).rejects.toThrow('--parameters must be a JSON object')
    await expect(main(['moderato', 'zoneRouter', 'extra'], '/nonexistent/earn')).rejects.toThrow(
      'Usage: pnpm zone-router-release',
    )
  })
})
