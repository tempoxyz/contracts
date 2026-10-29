import { deployLocalERC4626ScriptAbi, morphoFeeWrapperAbi } from '@tempoxyz/contracts/abis'
import { erc4626Abi } from 'viem'
import * as Foundry from '../foundry.js'
import { expectAddress, type LocalEngine, type LocalVenue } from './local-engine.js'

const fixture = Foundry.fixtureScript('DeployLocalERC4626', deployLocalERC4626ScriptAbi)

/**
 * A Simple ERC-4626 venue behind the Morpho fee-wrapper fixture, or on a persistent chain one with
 * locked seed liquidity; the lifecycle deploys the engine.
 */
export const erc4626: LocalEngine = {
  hostedFixture: { overPathUsd: false },
  async provision({ baseAsset, deploy, funder, persistent }): Promise<LocalVenue> {
    if (persistent) {
      if (!funder) throw new Error('A seeded ERC-4626 venue needs the stablecoin funder')
      const vault = await deploy(fixture('seededVault', [baseAsset, funder]))
      return { vault: vault.address, engineFixtures: {} }
    }
    const vault = await deploy(fixture('vault', [baseAsset]))
    const morphoFeeWrapper = await deploy(fixture('morphoFeeWrapper', [vault.address]))
    return { vault: vault.address, engineFixtures: { morphoFeeWrapper: morphoFeeWrapper.address } }
  },
  /** The venue holds the base asset, and the Morpho fee wrapper, when present, wraps that venue. */
  async validate(client, { baseAsset, vault, engineFixtures: { morphoFeeWrapper } }) {
    const [venueAsset, wrapper] = await Promise.all([
      client.readContract({ address: vault, abi: erc4626Abi, functionName: 'asset' }),
      morphoFeeWrapper &&
        Promise.all([
          client.readContract({
            address: morphoFeeWrapper,
            abi: morphoFeeWrapperAbi,
            functionName: 'asset',
          }),
          client.readContract({
            address: morphoFeeWrapper,
            abi: morphoFeeWrapperAbi,
            functionName: 'venue',
          }),
        ]),
    ])
    expectAddress(venueAsset, baseAsset, 'ERC-4626 venue asset')
    if (!wrapper) return
    expectAddress(wrapper[0], baseAsset, 'Morpho fee-wrapper asset')
    expectAddress(wrapper[1], vault, 'Morpho fee-wrapper venue')
  },
  profileEngine: (venue) => ({ kind: 'erc4626', venue }),
  metadata: {
    earnShare: { name: 'Tempo Earn Local Vault (Earn)', symbol: 'teLOCALE', decimals: 6 },
    venue: { name: 'Tempo Earn Local Vault', symbol: 'teLOCAL', decimals: 6 },
  },
}
