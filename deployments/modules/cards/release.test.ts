import {
  concatHex,
  createPublicClient,
  custom,
  decodeFunctionData,
  encodeAbiParameters,
  getAddress,
  getContractAddress,
  parseAbiParameters,
  type Address,
  type Hex,
} from 'viem'
import { describe, expect, test, vi } from 'vitest'

import { deployBridgeCardsScriptAbi } from '../../abis/index.js'
import {
  create2Deployer,
  predictRelease,
  releaseSalt,
  type FactoryReleaseDependencies,
} from '../../core/factory-release.js'
import { bridgeSpenderFactories } from './profile.js'
import {
  cardReleaseKinds,
  cardReleaseKindsFor,
  cardReleases,
  deployCardRelease,
  main,
  planCardRelease,
} from './release.js'

const address = (suffix: string) => getAddress(`0x${suffix.padStart(40, '0')}`)
const bytecode = (contract: string) =>
  `0x6080${Buffer.from(contract.split(':')[1]!).toString('hex')}` as Hex
const hash = (index: number) => `0x${String(index + 1).repeat(64)}` as Hex
const create2 = (initCode: Hex) =>
  getContractAddress({
    opcode: 'CREATE2',
    from: create2Deployer,
    salt: releaseSalt,
    bytecode: initCode,
  })

describe('planCardRelease', () => {
  test('the CardFactory binds the release ZoneRouterFactory, deployed first when missing', () => {
    const plan = planCardRelease('cardFactory', 42431)
    expect(plan).toMatchObject({
      kind: 'cardFactory',
      script: 'script/spend/bridge/lifecycle/DeployBridgeCards.s.sol:DeployBridgeCardsScript',
      parameters: {},
      forgeArguments: [],
    })
    expect(plan.registryKey).toBeUndefined()
    expect(decodeFunctionData({ abi: deployBridgeCardsScriptAbi, data: plan.calldata })).toEqual({
      functionName: 'cardFactory',
      args: [42431n],
    })
    const [routerFactory, cardFactory] = predictRelease(plan, bytecode)
    expect(routerFactory).toMatchObject({
      name: 'ZoneRouterFactory',
      address: create2(bytecode('src/zone/ZoneRouterFactory.sol:ZoneRouterFactory')),
    })
    const args = encodeAbiParameters(parseAbiParameters('address'), [routerFactory!.address])
    expect(cardFactory).toMatchObject({
      name: 'CardFactory',
      contract: 'src/spend/CardFactory.sol:CardFactory',
      constructorArgs: args,
      address: create2(concatHex([bytecode('src/spend/CardFactory.sol:CardFactory'), args])),
    })
    expect(cardReleases.cardFactory(bytecode)).toEqual({
      routerFactory: routerFactory!.address,
      cardFactory: cardFactory!.address,
    })
  })

  test("the TS handler needs the network's declared SpenderFactory", () => {
    expect(Object.values(bridgeSpenderFactories).every((factory) => factory === null)).toBe(true)
    for (const chainId of [42431, 4217, 1337])
      expect(() => planCardRelease('tempoSpend', chainId)).toThrow(
        `No Bridge SpenderFactory is declared for chain ${chainId}`,
      )
  })

  test('the TS handler, provider and CardFactory land where the scripts create them', () => {
    const factory = address('bf')
    const spenderId = `0x${'5'.repeat(64)}` as Hex
    expect(cardReleases.tempoSpend(factory, bytecode)).toBe(
      create2(
        concatHex([
          bytecode('src/spend/providers/bridge/SpenderTempoSpend.sol:SpenderTempoSpend'),
          encodeAbiParameters(parseAbiParameters('address'), [factory]),
        ]),
      ),
    )
    expect(cardReleases.bridgeProvider(factory, spenderId, bytecode)).toBe(
      create2(
        concatHex([
          bytecode('src/spend/providers/bridge/BridgeProvider.sol:BridgeProvider'),
          encodeAbiParameters(parseAbiParameters('address, bytes32'), [factory, spenderId]),
        ]),
      ),
    )
  })

  test('all releases nothing on a network without a declared SpenderFactory', () => {
    expect(cardReleaseKindsFor('all', 'moderato')).toEqual([])
    expect(cardReleaseKindsFor('all', 'mainnet')).toEqual([])
    for (const kind of cardReleaseKinds)
      expect(cardReleaseKindsFor(kind, 'moderato')).toEqual([kind])
    for (const kind of ['core', 'zoneRouterFactory', 'bridgeProgram'])
      expect(() => cardReleaseKindsFor(kind, 'moderato')).toThrow(`Unknown card release ${kind}`)
  })
})

describe('deployCardRelease', () => {
  const plan = planCardRelease('cardFactory', 42431)
  const predicted = predictRelease(plan, bytecode)
  function runtime(existing: readonly Address[] = []) {
    return {
      client: vi.fn(() => releaseClient(42431)),
      archiveBroadcast: vi.fn(),
      confirmCreations: vi.fn<FactoryReleaseDependencies['confirmCreations']>(
        async (_client, _plan, created) => [...created],
      ),
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
  const options = {
    network: 'moderato',
    kind: 'cardFactory',
    broadcast: true,
    root: '/repo',
    environment: { DEPLOYER_PRIVATE_KEY: '0xkey' },
  }

  test('creates only the missing CardFactory and source verifies both contracts', async () => {
    const [routerFactory, cardFactory] = predicted
    const dependencies = runtime([routerFactory!.address])
    dependencies.readFile.mockImplementation(() =>
      JSON.stringify({
        transactions: [
          {
            transactionType: 'CREATE2',
            contractName: 'CardFactory',
            contractAddress: cardFactory!.address,
            hash: hash(0),
            transaction: { input: concatHex([releaseSalt, cardFactory!.initCode]) },
          },
        ],
        receipts: [{ transactionHash: hash(0), status: '0x1' }],
      }),
    )
    const result = await deployCardRelease(options, dependencies)
    expect(dependencies.forge).toHaveBeenCalledOnce()
    expect(dependencies.removeScriptCache).toHaveBeenCalledWith('/repo', 'DeployBridgeCards.s.sol')
    expect(dependencies.verify.mock.calls.map(([call]) => call.contract)).toEqual([
      'src/zone/ZoneRouterFactory.sol:ZoneRouterFactory',
      'src/spend/CardFactory.sol:CardFactory',
    ])
    expect(result).toMatchObject({
      kind: 'cardFactory',
      registry: null,
      contracts: [
        { name: 'ZoneRouterFactory', transaction: null, match: 'exact_match' },
        { name: 'CardFactory', transaction: hash(0), match: 'exact_match' },
      ],
    })
  })

  test('reconciles a release that already exists without running Forge', async () => {
    const dependencies = runtime(predicted.map((contract) => contract.address))
    const result = await deployCardRelease(options, dependencies)
    expect(dependencies.forge).not.toHaveBeenCalled()
    expect(result).toMatchObject({ kind: 'cardFactory', current: true, registry: null })
  })

  test('refuses a release that created something other than the missing contracts', async () => {
    const dependencies = runtime()
    await expect(deployCardRelease(options, dependencies)).rejects.toThrow(
      'The cardFactory release created nothing, expected CardFactory, ZoneRouterFactory',
    )
  })
})

describe('card release CLI', () => {
  test('refuses unknown networks and releases before deploying anything', async () => {
    await expect(main(['devnet', 'all'], '/nonexistent')).rejects.toThrow(
      'Unknown hosted network devnet',
    )
    await expect(main(['moderato', 'bridgeProgram'], '/nonexistent')).rejects.toThrow(
      'Unknown card release bridgeProgram',
    )
    await expect(main(['moderato'], '/nonexistent')).rejects.toThrow('Usage: pnpm card-release')
  })
})

function releaseClient(chainId: number) {
  return createPublicClient({
    transport: custom({
      request: async ({ method }) => {
        if (method === 'eth_chainId') return `0x${chainId.toString(16)}`
        throw new Error(`Unexpected release RPC ${method}`)
      },
    }),
  })
}
