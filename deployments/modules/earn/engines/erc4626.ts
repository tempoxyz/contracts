import {
  encodeAbiParameters,
  encodeFunctionData,
  getAbiItem,
  getAddress,
  zeroAddress,
  erc4626Abi,
  erc20Abi,
  parseAbiParameters,
  toFunctionSelector,
} from 'viem'

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
    creationEvent: getAbiItem({ abi: erc4626EngineFactoryAbi, name: 'ERC4626EngineDeployed' }),
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
  recognizes: (client, engine) =>
    client.readContract({
      address: engine,
      abi: erc4626EngineAbi,
      functionName: 'supportsInterface',
      args: [toFunctionSelector('depositInKind(uint256,address)')],
    }),
  shareScale: (client, engine) =>
    client.readContract({
      address: engine,
      abi: erc4626EngineAbi,
      functionName: 'shareScale',
    }),
  readVenue: (client, engine) =>
    client.readContract({ address: engine, abi: erc4626EngineAbi, functionName: 'vault' }),
  async inspectBindings(client, engine) {
    const contract = { address: engine, abi: erc4626EngineAbi } as const
    const [vault, baseAsset, asset, shareScale] = await Promise.all([
      client.readContract({ ...contract, functionName: 'vault' }),
      client.readContract({ ...contract, functionName: 'baseAsset' }),
      client.readContract({ ...contract, functionName: 'asset' }),
      client.readContract({ ...contract, functionName: 'shareScale' }),
    ])
    if (getAddress(vault) === zeroAddress) throw new Error('ERC-4626 vault is zero')
    if (getAddress(baseAsset) === zeroAddress) throw new Error('ERC-4626 asset is zero')
    if (getAddress(asset) !== getAddress(baseAsset))
      throw new Error('ERC-4626 engine asset binding differs from baseAsset')
    for (const [label, address] of Object.entries({ vault, asset: baseAsset })) {
      const code = await client.getCode({ address })
      if (!code || code === '0x') throw new Error(`ERC-4626 ${label} has no runtime code`)
    }
    const [venueAsset, decimals] = await Promise.all([
      client.readContract({ address: vault, abi: erc4626Abi, functionName: 'asset' }),
      client.readContract({ address: vault, abi: erc20Abi, functionName: 'decimals' }),
    ])
    if (getAddress(venueAsset) !== getAddress(baseAsset))
      throw new Error('ERC-4626 venue asset differs from immutable engine baseAsset')
    if (decimals > 77) throw new Error('ERC-4626 venue share decimals exceed 77')
    // shareScale() returns the private constructor-derived _shareScale, not a live venue calculation.
    if (shareScale !== 10n ** BigInt(decimals))
      throw new Error('ERC-4626 immutable share scale differs from venue share decimals')
    return undefined
  },
  // The engine deposits into the venue and holds exactly the venue shares it mints.
  quoteDeposit: (client, { venue }, assets) =>
    client.readContract({
      address: venue,
      abi: erc4626Abi,
      functionName: 'previewDeposit',
      args: [assets],
    }),
})
