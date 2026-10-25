import type { Address } from 'viem'

import { vedaAccountantAbi, vedaEngineAbi, vedaTellerAbi } from '../../abis/index.js'
import type { DeploymentContracts } from '../../core/stack.js'
import { defineEngine, type PeripheryContract } from './engine.js'
import { inspectVedaEngine, readVedaStackPeriphery } from './veda-inspection.js'

/**
 * The Veda contracts a stack records beside the engine and BoringVault, in display order. A profile
 * stack derives all but the liquidity buffer from what the engine reports through
 * `inspectVedaPeriphery`; only a hand-authored catalog stack records a liquidity buffer.
 */
const vedaPeripheryContracts = [
  { name: 'teller', label: 'Teller' },
  { name: 'accountant', label: 'Accountant' },
  { name: 'queue', label: 'Queue', optional: true },
  { name: 'peripheryRegistry', label: 'periphery registry' },
  { name: 'rolesAuthority', label: 'RolesAuthority' },
] as const satisfies readonly PeripheryContract[]

type VedaPeripheryContract = (typeof vedaPeripheryContracts)[number]

/** The typed Veda periphery addresses: required contracts, plus the optional Queue when present. */
export type VedaPeriphery = {
  [
    Contract in VedaPeripheryContract as Contract extends { optional: true }
      ? never
      : Contract['name']
  ]: Address
} & {
  [
    Contract in VedaPeripheryContract as Contract extends { optional: true }
      ? Contract['name']
      : never
  ]?: Address | undefined
}

/** The Veda periphery of a Veda stack; throws when a required contract is absent. */
export function vedaPeriphery(contracts: Pick<DeploymentContracts, 'periphery'>): VedaPeriphery {
  const entries: [string, Address][] = []
  for (const contract of vedaPeripheryContracts) {
    const address = contracts.periphery?.[contract.name]
    if (address) entries.push([contract.name, address])
    else if (!('optional' in contract)) {
      throw new Error(`Veda stack is missing periphery ${contract.name}`)
    }
  }
  return Object.fromEntries(entries) as VedaPeriphery
}

/** A BoringVault behind its Teller, Accountant, and optional Queue; see `docs/modules/veda.md`. */
export const veda = defineEngine({
  label: 'Veda',
  engineContract: 'VedaEngine',
  engineSource: 'src/engines/veda/VedaEngine.sol',
  venueLabel: 'BoringVault',
  venueDetail: 'Illustrative Veda contract set',
  periphery: vedaPeripheryContracts,
  exitSolver: 'VedaForwardingSolver',
  capabilities: {
    inKindDeposit: false,
    redeem: true,
    boundedRedeem: true,
    exactWithdraw: true,
    asyncRedeem: true,
  },
  readVenue: (client, engine) =>
    client.readContract({ address: engine, abi: vedaEngineAbi, functionName: 'vault' }),
  readPeriphery: readVedaStackPeriphery,
  async inspectBindings(client, engine, mode) {
    await inspectVedaEngine(client, engine, mode)
    return undefined
  },
  /** The Teller's deposit at the Accountant's safe rate, less the asset's share premium. */
  async quoteDeposit(client, { asset, engine }, assets) {
    const contract = { address: engine, abi: vedaEngineAbi } as const
    const [accountant, shareScale, teller] = await Promise.all([
      client.readContract({ ...contract, functionName: 'accountant' }),
      client.readContract({ ...contract, functionName: 'shareScale' }),
      client.readContract({ ...contract, functionName: 'teller' }),
    ])
    const [rate, [allowDeposits, , sharePremium]] = await Promise.all([
      client.readContract({
        address: accountant,
        abi: vedaAccountantAbi,
        functionName: 'getRateInQuoteSafe',
        args: [asset],
      }),
      client.readContract({
        address: teller,
        abi: vedaTellerAbi,
        functionName: 'assetData',
        args: [asset],
      }),
    ])
    if (rate === 0n) throw new Error('Veda Accountant returned a zero asset rate')
    if (!allowDeposits) throw new Error('Veda Teller does not accept the EarnVault asset')
    if (sharePremium > 10_000) throw new Error('Veda Teller returned an invalid share premium')
    // TellerWithYieldStreaming deliberately adds one to the safe-rate denominator.
    const sharesBeforePremium = (assets * shareScale) / (rate + 1n)
    return (sharesBeforePremium * BigInt(10_000 - sharePremium)) / 10_000n
  },
})
