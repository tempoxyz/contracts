import { encodeAbiParameters, encodeFunctionData, erc4626Abi, parseAbiParameters } from 'viem'

import {
  deployERC4626EngineScriptAbi,
  erc4626EngineAbi,
  erc4626EngineFactoryAbi,
} from '../../../abis/index.js'
import { defineEngine } from './engine.js'

/** One conforming ERC-4626 vault; see `docs/earn/modules/erc4626-engine.md`. */
export const erc4626 = defineEngine({
  label: 'ERC-4626',
  engineContract: 'ERC4626Engine',
  engineSource: 'src/engines/ERC4626Engine.sol',
  venueLabel: 'ERC-4626 vault',
  venueDetail: 'Yield source',
  periphery: [],
  capabilities: {
    inKindDeposit: true,
    redeem: true,
    boundedRedeem: true,
    exactWithdraw: true,
    asyncRedeem: false,
  },
  factory: {
    contract: 'ERC4626EngineFactory',
    source: 'src/engines/ERC4626EngineFactory.sol',
    releaseKey: 'erc4626Engine',
    deployScript: 'script/deploy/DeployERC4626Engine.s.sol:DeployERC4626EngineScript',
    deployInput: (input) =>
      encodeFunctionData({
        abi: deployERC4626EngineScriptAbi,
        functionName: 'run',
        args: [input],
      }),
    releaseInput: (expectedChainId) =>
      encodeFunctionData({
        abi: deployERC4626EngineScriptAbi,
        functionName: 'erc4626EngineFactory',
        args: [expectedChainId],
      }),
    predictEngine: (client, factory, { deploymentId, venue, owner }) =>
      client.readContract({
        address: factory,
        abi: erc4626EngineFactoryAbi,
        functionName: 'predictEngine',
        args: [deploymentId, venue, owner, '', ''],
      }),
    engineConstructorArgs: ({ venue, owner }) =>
      encodeAbiParameters(
        parseAbiParameters(
          'address vault, address owner, string nameOverride, string symbolOverride',
        ),
        [venue, owner, '', ''],
      ),
    venueAsset: (client, venue) =>
      client.readContract({ address: venue, abi: erc4626Abi, functionName: 'asset' }),
  },
  readVenue: (client, engine) =>
    client.readContract({ address: engine, abi: erc4626EngineAbi, functionName: 'vault' }),
  // The engine deposits into the venue and holds exactly the venue shares it mints.
  quoteDeposit: (client, { venue }, assets) =>
    client.readContract({
      address: venue,
      abi: erc4626Abi,
      functionName: 'previewDeposit',
      args: [assets],
    }),
})
