import {
  getAddress,
  toFunctionSelector,
  zeroAddress,
  type Address,
  type Hex,
  type PublicClient,
} from 'viem'

import {
  vedaAccountantAbi,
  vedaBoringQueueAbi,
  vedaBoringVaultAbi,
  vedaEngineAbi,
  vedaPeripheryRegistryAbi,
  vedaRolesAuthorityAbi,
  vedaTellerAbi,
} from '../../../abis/index.js'
import { InspectionMismatchError } from '../../../chain/inspect.js'
import type { VedaPeriphery } from './veda.js'

const bulkDeposit = toFunctionSelector('bulkDeposit(address,uint256,uint256,address)')
const bulkWithdraw = toFunctionSelector('bulkWithdraw(address,uint256,uint256,address)')
const requestOnChainWithdraw = toFunctionSelector(
  'requestOnChainWithdraw(address,uint128,uint16,uint24)',
)
const cancelOnChainWithdraw = toFunctionSelector('cancelOnChainWithdrawUsingRequestId(bytes32)')

/**
 * The "Veda engine verified" gate, read from the engine alone: the periphery wiring and Teller
 * capabilities `inspectVedaPeriphery` checks, plus, in queued mode, a tracked Queue whose authority
 * grants the engine its request and ID-based cancellation capabilities. `ready` adds a fresh,
 * nonzero rate and open base-asset deposits.
 */
export async function inspectVedaEngine(
  client: Pick<PublicClient, 'readContract'>,
  engine: Address,
  mode: 'ready' | 'bindings' = 'ready',
) {
  const { asset, queue, teller } = await inspectVedaPeriphery(client, engine)
  if (queue !== zeroAddress) {
    const [queueAuthority, tracking] = await Promise.all([
      client.readContract({ address: queue, abi: vedaBoringVaultAbi, functionName: 'authority' }),
      client.readContract({
        address: queue,
        abi: vedaBoringQueueAbi,
        functionName: 'trackWithdrawsOnChain',
      }),
    ])
    if (!tracking)
      throw new InspectionMismatchError('Veda Queue does not track withdrawals onchain')
    await expectCapabilities(client, engine, [
      [queueAuthority, queue, requestOnChainWithdraw, 'Queue requestOnChainWithdraw'],
      [queueAuthority, queue, cancelOnChainWithdraw, 'Queue ID-based cancellation'],
    ])
  }
  if (mode === 'bindings') return

  const engineContract = { address: engine, abi: vedaEngineAbi } as const
  const [fresh, rate, [allowDeposits]] = await Promise.all([
    client.readContract({ ...engineContract, functionName: 'isFeeValuationFresh' }),
    client.readContract({ ...engineContract, functionName: 'rate' }),
    client.readContract({
      address: teller,
      abi: vedaTellerAbi,
      functionName: 'assetData',
      args: [asset],
    }),
  ])
  if (!fresh) throw new Error('Veda Accountant rate is older than the engine maxRateAge')
  if (rate === 0n) throw new Error('Veda Accountant returned a zero base-asset rate')
  if (!allowDeposits) throw new Error('Veda Teller does not accept the EarnVault asset')
}

/**
 * The Veda wiring every engine flow depends on, read from the engine alone: the registry and engine
 * agree on one periphery tuple and point back at each other at the published version, the
 * Accountant prices the BoringVault in the engine's asset, and the vault's RolesAuthority grants the
 * engine Teller `bulkDeposit` and `bulkWithdraw`. Returns the periphery the engine reports so
 * callers can compare it with their own records. A wiring failure throws `InspectionMismatchError`;
 * a failed read throws its own error.
 */
export async function inspectVedaPeriphery(
  client: Pick<PublicClient, 'readContract'>,
  engine: Address,
) {
  const engineContract = { address: engine, abi: vedaEngineAbi } as const
  const [registry, vault, asset, teller, queue, accountant, version] = await Promise.all([
    client.readContract({ ...engineContract, functionName: 'peripheryRegistry' }),
    client.readContract({ ...engineContract, functionName: 'vault' }),
    client.readContract({ ...engineContract, functionName: 'asset' }),
    client.readContract({ ...engineContract, functionName: 'teller' }),
    client.readContract({ ...engineContract, functionName: 'queue' }),
    client.readContract({ ...engineContract, functionName: 'accountant' }),
    client.readContract({ ...engineContract, functionName: 'peripheryVersion' }),
  ])
  const registryContract = { address: registry, abi: vedaPeripheryRegistryAbi } as const
  const [
    registryEngine,
    registryVault,
    registryAsset,
    registryTeller,
    registryQueue,
    registryAccountant,
    registryVersion,
    accountantVault,
    accountantBase,
    authority,
  ] = await Promise.all([
    client.readContract({ ...registryContract, functionName: 'engine' }),
    client.readContract({ ...registryContract, functionName: 'vault' }),
    client.readContract({ ...registryContract, functionName: 'baseAsset' }),
    client.readContract({ ...registryContract, functionName: 'teller' }),
    client.readContract({ ...registryContract, functionName: 'queue' }),
    client.readContract({ ...registryContract, functionName: 'accountant' }),
    client.readContract({ ...registryContract, functionName: 'version' }),
    client.readContract({ address: accountant, abi: vedaAccountantAbi, functionName: 'vault' }),
    client.readContract({ address: accountant, abi: vedaAccountantAbi, functionName: 'base' }),
    client.readContract({ address: vault, abi: vedaBoringVaultAbi, functionName: 'authority' }),
  ])
  expectAddress(registryEngine, engine, 'Veda registry engine')
  expectAddress(registryVault, vault, 'Veda registry BoringVault')
  expectAddress(registryAsset, asset, 'Veda registry base asset')
  expectAddress(registryTeller, teller, 'Veda registry Teller')
  expectAddress(registryQueue, queue, 'Veda registry Queue')
  expectAddress(registryAccountant, accountant, 'Veda registry Accountant')
  if (registryVersion === 0n || version !== registryVersion) {
    throw new InspectionMismatchError(
      `VedaEngine periphery version ${version} is not the registry's published version ${registryVersion}`,
    )
  }
  expectAddress(accountantVault, vault, 'Veda Accountant BoringVault')
  expectAddress(accountantBase, asset, 'Veda Accountant base asset')
  await expectCapabilities(client, engine, [
    [authority, teller, bulkDeposit, 'Teller bulkDeposit'],
    [authority, teller, bulkWithdraw, 'Teller bulkWithdraw'],
  ])
  return {
    registry: getAddress(registry),
    vault: getAddress(vault),
    asset: getAddress(asset),
    teller: getAddress(teller),
    queue: getAddress(queue),
    accountant: getAddress(accountant),
    authority: getAddress(authority),
  }
}

/** The stack periphery record the engine reports, after `inspectVedaPeriphery` verifies its wiring. */
export async function readVedaStackPeriphery(
  client: Pick<PublicClient, 'readContract'>,
  engine: Address,
): Promise<VedaPeriphery> {
  const { accountant, authority, queue, registry, teller } = await inspectVedaPeriphery(
    client,
    engine,
  )
  return {
    teller,
    accountant,
    ...(queue === zeroAddress ? {} : { queue }),
    peripheryRegistry: registry,
    rolesAuthority: authority,
  }
}

async function expectCapabilities(
  client: Pick<PublicClient, 'readContract'>,
  engine: Address,
  capabilities: readonly (readonly [
    roles: Address,
    target: Address,
    selector: Hex,
    label: string,
  ])[],
) {
  const granted = await Promise.all(
    capabilities.map(([roles, target, selector]) =>
      client.readContract({
        address: roles,
        abi: vedaRolesAuthorityAbi,
        functionName: 'canCall',
        args: [engine, target, selector],
      }),
    ),
  )
  capabilities.forEach(([, , , label], index) => {
    if (!granted[index])
      throw new InspectionMismatchError(`VedaEngine lacks the ${label} capability`)
  })
}

function expectAddress(actual: Address, expected: Address, label: string) {
  if (getAddress(actual) !== getAddress(expected)) {
    throw new InspectionMismatchError(
      `${label} ${getAddress(actual)} is not ${getAddress(expected)}`,
    )
  }
}
