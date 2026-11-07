import {
  encodeAbiParameters,
  getAddress,
  isAddressEqual,
  parseAbiParameters,
  zeroAddress,
} from 'viem'

import {
  deployLocalVedaScriptAbi,
  vedaEngineAbi,
  vedaForwardingSolverAbi,
  vedaPeripheryRegistryAbi,
} from '@tempoxyz/contracts/abis'
import * as Foundry from '../foundry.js'
import {
  expectAddress,
  type LocalEngine,
  type LocalVenue,
  type ProvisionContext,
} from './local-engine.js'

const fixture = Foundry.fixtureScript('DeployLocalVeda', deployLocalVedaScriptAbi)

/**
 * A BoringVault with its periphery, a queued replacement periphery, the engine bound to the
 * periphery registry, and the forwarding solver the engine owner authorizes before the lifecycle.
 * The engine accepts a rate one day old, or ten years on a persistent chain, whose fixture
 * Accountant never reports.
 */
async function provisionVeda({
  baseAsset,
  deploy,
  persistent,
  run,
}: ProvisionContext): Promise<LocalVenue> {
  const maxRateAge = persistent ? 10n * 365n * 86_400n : 86_400n
  const vault = await deploy(fixture('vault', [baseAsset]))
  const accountant = await deploy(fixture('accountant', [vault.address, baseAsset]))
  const teller = await deploy(fixture('teller', [vault.address, accountant.address, baseAsset]))
  const queue = await deploy(fixture('queue', [vault.address, accountant.address]))
  const stockSolver = await deploy(fixture('stockSolver', [queue.address]))
  const registry = await deploy(fixture('registry', [vault.address, baseAsset]))
  await run(
    fixture('publish', [registry.address, teller.address, queue.address, accountant.address]),
  )
  const nextAccountant = await deploy(fixture('accountant', [vault.address, baseAsset]))
  const nextTeller = await deploy(
    fixture('teller', [vault.address, nextAccountant.address, baseAsset]),
  )
  const nextQueue = await deploy(fixture('queue', [vault.address, nextAccountant.address]))
  await run(fixture('configure', [teller.address, nextTeller.address]))
  const engine = await deploy(
    fixture('engine', [registry.address, maxRateAge], {
      rawGasEstimate: true,
      // Accepts only the candidate that is an unbound engine over this periphery registry.
      async resolveAddress({ candidates, client }) {
        for (const candidate of candidates) {
          try {
            const contract = { address: candidate, abi: vedaEngineAbi } as const
            const [binding, earnVault] = await Promise.all([
              client.readContract({ ...contract, functionName: 'peripheryRegistry' }),
              client.readContract({ ...contract, functionName: 'earnVault' }),
            ])
            if (
              isAddressEqual(binding, registry.address) &&
              isAddressEqual(earnVault, zeroAddress)
            ) {
              return getAddress(candidate)
            }
          } catch {
            // Candidate is not the engine deployed by this step.
          }
        }
        throw new Error('Veda engine broadcast did not identify the engine it deployed')
      },
    }),
  )
  await run(fixture('bindEngine', [registry.address, engine.address]))
  // The forwarder binds only the engine, so its owner authorizes it before the lifecycle runs.
  const forwardingSolver = await deploy(
    fixture('forwarder', [stockSolver.address, queue.address, teller.address, engine.address]),
  )
  await run(fixture('authorize', [engine.address, forwardingSolver.address]))
  return {
    vault: vault.address,
    engine: engine.address,
    engineFixtures: {
      accountant: accountant.address,
      forwardingSolver: forwardingSolver.address,
      nextAccountant: nextAccountant.address,
      nextQueue: nextQueue.address,
      nextTeller: nextTeller.address,
      queue: queue.address,
      registry: registry.address,
      stockSolver: stockSolver.address,
      teller: teller.address,
    },
  }
}

export const veda: LocalEngine = {
  hostedFixture: {
    overPathUsd: true,
    async engineConstructorArgs(client, engine) {
      const contract = { address: engine, abi: vedaEngineAbi } as const
      const [registry, owner, maxRateAge, name, symbol] = await Promise.all([
        client.readContract({ ...contract, functionName: 'peripheryRegistry' }),
        client.readContract({ ...contract, functionName: 'owner' }),
        client.readContract({ ...contract, functionName: 'maxRateAge' }),
        client.readContract({ ...contract, functionName: 'name' }),
        client.readContract({ ...contract, functionName: 'symbol' }),
      ])
      return encodeAbiParameters(parseAbiParameters('address, address, uint64, string, string'), [
        registry,
        owner,
        maxRateAge,
        name,
        symbol,
      ])
    },
  },
  provision: provisionVeda,
  /** The periphery registry and the engine are bound to each other. */
  async validate(client, { baseAsset, engine, vault, engineFixtures }) {
    const { registry, queue, teller, accountant, forwardingSolver, stockSolver } = engineFixtures
    if (!queue || !teller || !accountant || !forwardingSolver || !stockSolver)
      throw new Error('Veda fixtures need their active periphery and forwarding solver')
    if (!engine || !registry) throw new Error('Veda fixtures need the engine and its registry')
    const [registryEngine, engineRegistry] = await Promise.all([
      client.readContract({
        address: registry,
        abi: vedaPeripheryRegistryAbi,
        functionName: 'engine',
      }),
      client.readContract({
        address: engine,
        abi: vedaEngineAbi,
        functionName: 'peripheryRegistry',
      }),
    ])
    expectAddress(registryEngine, engine, 'Veda registry engine')
    expectAddress(engineRegistry, registry, 'Veda engine periphery registry')
    // A matching old runtime does not establish that the engine still uses that periphery.
    const contract = { address: engine, abi: vedaEngineAbi } as const
    const [activeQueue, activeTeller, activeAccountant, engineVault, engineAsset, authorized] =
      await Promise.all([
        client.readContract({ ...contract, functionName: 'queue' }),
        client.readContract({ ...contract, functionName: 'teller' }),
        client.readContract({ ...contract, functionName: 'accountant' }),
        client.readContract({ ...contract, functionName: 'vault' }),
        client.readContract({ ...contract, functionName: 'asset' }),
        client.readContract({
          ...contract,
          functionName: 'authorizedForwarder',
          args: [forwardingSolver],
        }),
      ])
    expectAddress(activeQueue, queue, 'Veda fixture active queue')
    expectAddress(activeTeller, teller, 'Veda fixture active teller')
    expectAddress(activeAccountant, accountant, 'Veda fixture active accountant')
    expectAddress(engineVault, vault, 'Veda fixture vault')
    expectAddress(engineAsset, baseAsset, 'Veda fixture asset')
    if (!authorized) throw new Error('Veda fixture forwarding solver is not authorized')
    const forwarder = { address: forwardingSolver, abi: vedaForwardingSolverAbi } as const
    const [solverQueue, solverTeller, solverEngine, solver] = await Promise.all([
      client.readContract({ ...forwarder, functionName: 'queue' }),
      client.readContract({ ...forwarder, functionName: 'teller' }),
      client.readContract({ ...forwarder, functionName: 'engine' }),
      client.readContract({ ...forwarder, functionName: 'boringSolver' }),
    ])
    expectAddress(solverQueue, queue, 'Veda fixture forwarder queue')
    expectAddress(solverTeller, teller, 'Veda fixture forwarder teller')
    expectAddress(solverEngine, engine, 'Veda fixture forwarder engine')
    expectAddress(solver, stockSolver, 'Veda fixture stock solver')
  },
  profileEngine: (address) => ({ kind: 'veda', address }),
  metadata: {
    earnShare: { name: 'Local Veda Vault (Earn)', symbol: 'teVEDAE', decimals: 6 },
    venue: { name: 'Local Veda Vault', symbol: 'teVEDA', decimals: 6 },
  },
}
