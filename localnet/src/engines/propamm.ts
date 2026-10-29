import { deployLocalPropAMMScriptAbi } from '@tempoxyz/contracts/abis'
import * as Foundry from '../foundry.js'
import type { LocalEngine } from './local-engine.js'

const fixture = Foundry.fixtureScript('DeployLocalPropAMM', deployLocalPropAMMScriptAbi)

/**
 * The unmodified PropAMM pool over a disposable base token, always-fresh oracle, and recipient
 * registry, with its engine configured and quote inventory funded before the lifecycle binds it.
 * The engine belongs to a separate setup owner, as a factory-less engine does on a hosted chain, so
 * every PropAMM stack exercises the `bind-core` owner handoff.
 */
export const propamm: LocalEngine = {
  hostedFixture: false,
  async provision({ baseAsset, deploy, deployAsEngineOwner, run, inventory, fundInventory }) {
    const vault = await deploy(fixture('token', []))
    const oracle = await deploy(fixture('oracle', []))
    const registry = await deploy(Foundry.earnFixture('routerPoolRegistry', []))
    const pool = await deploy(
      Foundry.earnFixture('routerPool', [
        vault.address,
        baseAsset,
        oracle.address,
        registry.address,
      ]),
    )
    const engine = await deployAsEngineOwner(fixture('engine', [pool.address]))
    await run(fixture('configure', [vault.address, pool.address, engine.address, inventory]))
    await fundInventory(baseAsset, pool.address, 'PropAMM engine pool quote')
    return { vault: vault.address, engine: engine.address, engineFixtures: {} }
  },
  profileEngine: (address) => ({ kind: 'propamm', address }),
  metadata: {
    earnShare: { name: 'PropAMM Engine (Earn)', symbol: 'propAMM-engineE', decimals: 6 },
    venue: { name: 'Local Base Token', symbol: 'BASE', decimals: 6 },
  },
}
