import {
  encodeFunctionData,
  erc20Abi,
  getAbiItem,
  getAddress,
  isAddress,
  parseAbi,
  toEventSelector,
  zeroAddress,
  type Address,
  type Hex,
  type PublicClient,
} from 'viem'

import { earnVaultAbi, zonePortalAbi, zoneRouterAbi } from '../../abis/index.js'
import type { EarnDeploymentProfile } from '../../core/profile.js'
import { configuredZone } from '../earn/zone-router/profile.js'
import { requiredOutput } from '../module.js'
import { missingGetter } from './inspection.js'
import { configuredZoneRouter } from './profile.js'

/**
 * A token whose TIP-20 balance slot a contract keeps nonzero with 1 base unit. A Zone router and a
 * SendSpender hold a token only while a callback runs, so without the unit every callback creates the
 * slot again, which Tempo charges 250,000 gas unless a TIP-1060 storage credit covers it.
 */
export type ZoneRouterSeed = {
  holder: Address
  holderLabel: string
  token: Address
  tokenLabel: string
}

/** A token the router returns to its Zone, whose standing Portal allowance `warm` sets. */
export type ZoneRouterWarm = { token: Address; tokenLabel: string }

/** The units the router and its SendSpenders should hold, and the tokens the router should warm. */
export type ZoneRouterSeedPlan = {
  router: Address
  portal: Address
  seeds: ZoneRouterSeed[]
  warm: ZoneRouterWarm[]
}

type SeedClient = Pick<PublicClient, 'getCode' | 'getStorageAt' | 'readContract'>

// EIP-1967: bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1).
const implementationSlot = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc'
const restartTopic = toEventSelector(
  getAbiItem({ abi: earnVaultAbi, name: 'UnbackedPoolRestarted' }),
)
  .slice(2)
  .toLowerCase()
const spenderAbi = parseAbi([
  'function PROVIDER() view returns (address)',
  'function convertVault() view returns (address)',
  'function convertAsset() view returns (address)',
  'function parToken() view returns (address)',
])

/**
 * Whether the profile has the router's Portal enable EarnShare: through this mode's Earn binding, or
 * through the single-Zone router on the same Zone. Inspection reads the Portal itself.
 */
export function enablesEarnShare(profile: EarnDeploymentProfile) {
  const router = profile.zoneRouter
  return (
    router !== null && (router.earn !== undefined || configuredZone(profile)?.id === router.zoneId)
  )
}

/**
 * Whether the vault is an EarnVault proxy whose implementation emits UnbackedPoolRestarted. Only such a
 * vault lets an EarnShare unit stay held for good: an earlier one could never return its supply to zero
 * once every other holder exits, so nothing bound to it may receive EarnShare.
 */
export async function vaultRestartsUnbackedPools(client: SeedClient, vault: Address) {
  const slot = await client.getStorageAt({ address: vault, slot: implementationSlot })
  if (!slot || BigInt(slot) === 0n) return false
  const code = await client.getCode({ address: getAddress('0x' + slot.slice(-40)) })
  return code !== undefined && code.toLowerCase().includes(restartTopic)
}

/**
 * What the profile's router and its SendSpenders handle: an Earn router's vault asset and private
 * asset, each stack token its Portal enables for a Spend router, and each SendSpender's input tokens
 * plus the tokens it redeems or converts through. EarnShare units go only to contracts bound to a vault
 * that restarts unbacked pools; card programs follow their own runbook.
 */
export async function zoneRouterSeedPlan(
  client: SeedClient,
  profile: EarnDeploymentProfile,
  outputs: Record<string, Address>,
): Promise<ZoneRouterSeedPlan> {
  const router = configuredZoneRouter(profile)
  const routerAddress = requiredOutput(outputs, 'zoneRouter')
  const portal = requiredOutput(outputs, 'zoneRouterPortal')
  const earnShare = requiredOutput(outputs, 'earnShare')
  const asset = requiredOutput(outputs, 'asset')
  const spends = router.ops.includes('spend')

  // Spend moves whatever its Zone withdraws; of the stack's tokens, those are the ones it enables.
  const candidates: [label: string, token: Address][] = [
    ...(router.earn ? [['private asset', router.earn.privateAsset] as [string, Address]] : []),
    ['vault asset', asset],
    ...(enablesEarnShare(profile) ? [['EarnShare', earnShare] as [string, Address]] : []),
  ]
  const enabled = spends
    ? await Promise.all(
        candidates.map(([, token]) =>
          client.readContract({
            address: portal,
            abi: zonePortalAbi,
            functionName: 'isTokenEnabled',
            args: [token],
          }),
        ),
      )
    : []
  const spendTokens = candidates.filter((_, index) => enabled[index] === true)
  const holdsEarnShare =
    router.earn !== undefined || spendTokens.some(([, token]) => token === earnShare)
  const restarts =
    holdsEarnShare &&
    (await vaultRestartsUnbackedPools(client, requiredOutput(outputs, 'earnVault')))

  const seeds: ZoneRouterSeed[] = []
  const warm: ZoneRouterWarm[] = []
  const seed = (holder: Address, holderLabel: string, token: Address, tokenLabel: string) => {
    if (token === zeroAddress) return
    if (token === earnShare && !restarts) return
    const entry = { holder, holderLabel, token: getAddress(token), tokenLabel }
    if (!seeds.some((other) => other.holder === holder && other.token === entry.token))
      seeds.push(entry)
  }
  const warmUp = (token: Address, tokenLabel: string) => {
    if (!warm.some((other) => other.token === getAddress(token)))
      warm.push({ token: getAddress(token), tokenLabel })
  }

  if (router.earn) {
    seed(routerAddress, 'Zone router', asset, 'vault asset')
    seed(routerAddress, 'Zone router', router.earn.privateAsset, 'private asset')
    seed(routerAddress, 'Zone router', earnShare, 'EarnShare')
    warmUp(earnShare, 'EarnShare')
    warmUp(router.earn.privateAsset, 'private asset')
  }
  for (const [label, token] of spendTokens) {
    seed(routerAddress, 'Zone router', token, label)
    warmUp(token, label)
  }

  for (const spender of spends ? (router.spenders ?? []) : []) {
    const binding = await sendSpenderBinding(client, spender)
    if (!binding) continue
    const label = 'SendSpender ' + spender
    for (const [tokenLabel, token] of spendTokens) seed(spender, label, token, tokenLabel)
    // An EarnShare spend redeems here when it converts or pays a virtual address.
    if (spendTokens.some(([, token]) => token === earnShare))
      seed(spender, label, asset, 'vault asset')
    if (binding.convertVault === zeroAddress) continue
    seed(spender, label, binding.convertAsset, 'conversion asset')
    seed(spender, label, binding.parToken, 'par token')
  }
  return { router: routerAddress, portal, seeds, warm }
}

/** The seeds each holder lacks and the tokens whose Portal allowance the router has not set. */
export async function missingZoneRouterSeeds(
  client: Pick<PublicClient, 'readContract'>,
  plan: ZoneRouterSeedPlan,
) {
  const [balances, allowances] = await Promise.all([
    Promise.all(
      plan.seeds.map((entry) =>
        client.readContract({
          address: entry.token,
          abi: erc20Abi,
          functionName: 'balanceOf',
          args: [entry.holder],
        }),
      ),
    ),
    Promise.all(
      plan.warm.map((entry) =>
        client.readContract({
          address: entry.token,
          abi: erc20Abi,
          functionName: 'allowance',
          args: [plan.router, plan.portal],
        }),
      ),
    ),
  ])
  return {
    seeds: plan.seeds.filter((_, index) => balances[index] === 0n),
    warm: plan.warm.filter((_, index) => allowances[index] === 0n),
  }
}

export type MissingZoneRouterSeeds = Awaited<ReturnType<typeof missingZoneRouterSeeds>>

/** One readiness line per missing seed or warm-up, naming the transfer or call that fixes it. */
export function zoneRouterSeedBlockers(plan: ZoneRouterSeedPlan, missing: MissingZoneRouterSeeds) {
  return [
    ...missing.seeds.map(
      (entry) =>
        entry.holderLabel +
        ' ' +
        entry.holder +
        ' holds no ' +
        entry.tokenLabel +
        ' ' +
        entry.token +
        ', so each callback recreates its balance slot: send it 1 base unit',
    ),
    ...missing.warm.map(
      (entry) =>
        'Zone router ' +
        plan.router +
        ' has no Portal allowance for ' +
        entry.tokenLabel +
        ' ' +
        entry.token +
        ', so its next return to the Zone sets one: call warm(' +
        entry.token +
        ')',
    ),
  ]
}

/** The calls that fix what is missing: a 1-unit transfer per seed and one warm call per token. */
export function zoneRouterSeedCalls(
  plan: ZoneRouterSeedPlan,
  missing: MissingZoneRouterSeeds,
): { to: Address; data: Hex }[] {
  return [
    ...missing.seeds.map((entry) => ({
      to: entry.token,
      data: encodeFunctionData({
        abi: erc20Abi,
        functionName: 'transfer',
        args: [entry.holder, 1n],
      }),
    })),
    ...missing.warm.map((entry) => ({
      to: plan.router,
      data: encodeFunctionData({ abi: zoneRouterAbi, functionName: 'warm', args: [entry.token] }),
    })),
  ]
}

/** A listed spender's conversion binding when it is a SendSpender; undefined for a card program. */
async function sendSpenderBinding(client: Pick<PublicClient, 'readContract'>, spender: Address) {
  const read = async (functionName: (typeof spenderAbi)[number]['name']) => {
    const value: unknown = await client
      .readContract({ address: spender, abi: spenderAbi, functionName })
      .catch(missingGetter)
    return typeof value === 'string' && isAddress(value) ? getAddress(value) : undefined
  }
  if (await read('PROVIDER')) return undefined
  const [convertVault, convertAsset, parToken] = await Promise.all([
    read('convertVault'),
    read('convertAsset'),
    read('parToken'),
  ])
  if (!convertVault || !convertAsset || !parToken) return undefined
  return { convertVault, convertAsset, parToken }
}
