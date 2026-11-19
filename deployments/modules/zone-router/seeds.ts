import {
  BaseError,
  encodeFunctionData,
  erc20Abi,
  getAbiItem,
  ExecutionRevertedError,
  getAddress,
  isAddress,
  parseAbi,
  toEventSelector,
  toFunctionSelector,
  zeroAddress,
  type Address,
  type Hex,
  type PublicClient,
} from 'viem'

import { earnVaultAbi, zonePortalAbi, zoneRouterAbi } from '../../abis/index.js'
import type { EarnDeploymentProfile } from '../../core/profile.js'
import { configuredZone } from '../earn/zone-router/profile.js'
import { requiredOutput } from '../module.js'
import {
  isCardProgram,
  missingGetter,
  releaseSendSpender,
  spenderProvenanceBlockers,
  type SpenderReleases,
} from './inspection.js'
import { configuredZoneRouter, zoneRouterFactory } from './profile.js'
import { spenderReleases } from './releases.js'

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

/**
 * The units the router and its SendSpenders should hold, the tokens the router should warm, the listed
 * spenders this tooling will not seed because they are not verified, and notes on units it withholds.
 */
export type ZoneRouterSeedPlan = {
  router: Address
  portal: Address
  seeds: ZoneRouterSeed[]
  warm: ZoneRouterWarm[]
  /** Why each listed spender that is neither a card program nor the release SendSpender is not seeded. */
  unverified: string[]
  /** Units deliberately not sent, such as EarnShare to contracts bound to an earlier vault. */
  notes: string[]
}

type SeedClient = Pick<PublicClient, 'call' | 'getCode' | 'getStorageAt' | 'readContract'>

// EIP-1967: bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1).
const implementationSlot = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc'
const restartTopic = toEventSelector(
  getAbiItem({ abi: earnVaultAbi, name: 'UnbackedPoolRestarted' }),
)
  .slice(2)
  .toLowerCase()
const sendSpenderAbi = parseAbi([
  'function convertAsset() view returns (address)',
  'function parToken() view returns (address)',
])

/**
 * Whether the profile has the router's Portal enable EarnShare: through this mode's Earn binding, or
 * through the profile's Zone when it is the same Zone. Planning uses it before any chain read;
 * inspection and seeding read the Portal itself.
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
 * asset, each stack token its Portal enables for a Spend router (EarnShare included, whatever the
 * profile), and each release SendSpender's input tokens plus the stack tokens it redeems or converts
 * through. EarnShare units go only to contracts bound to a vault that restarts unbacked pools, though
 * the router still warms its EarnShare allowance; card programs follow their own runbook, and any
 * other spender is reported as unverified and sent nothing.
 */
export async function zoneRouterSeedPlan(
  client: SeedClient,
  profile: EarnDeploymentProfile,
  outputs: Record<string, Address>,
  releases: SpenderReleases = spenderReleases,
): Promise<ZoneRouterSeedPlan> {
  const router = configuredZoneRouter(profile)
  const routerAddress = requiredOutput(outputs, 'zoneRouter')
  const portal = requiredOutput(outputs, 'zoneRouterPortal')
  const earnShare = requiredOutput(outputs, 'earnShare')
  const asset = requiredOutput(outputs, 'asset')
  const spends = router.ops.includes('spend')

  // Spend moves whatever its Zone withdraws; of the stack's tokens, those are the ones it enables.
  // These are also the only tokens seeded at all: a spender's getters never add a token outside them.
  const privateAsset = router.earn?.privateAsset
  const candidates: [label: string, token: Address][] = []
  for (const [label, token] of [
    ...(privateAsset ? [['private asset', privateAsset] as [string, Address]] : []),
    ['vault asset', asset],
    ['EarnShare', earnShare],
  ] as [string, Address][]) {
    if (!candidates.some(([, other]) => getAddress(other) === getAddress(token)))
      candidates.push([label, token])
  }
  const known = new Map(candidates.map(([label, token]) => [getAddress(token), label]))
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
  const earnVault = holdsEarnShare ? requiredOutput(outputs, 'earnVault') : zeroAddress
  const restarts = holdsEarnShare && (await vaultRestartsUnbackedPools(client, earnVault))

  const seeds: ZoneRouterSeed[] = []
  const warm: ZoneRouterWarm[] = []
  const notes: string[] = []
  const unverified: string[] = []
  if (holdsEarnShare && !restarts) {
    notes.push(
      `EarnShare units withheld: EarnVault ${earnVault} does not restart unbacked pools, so nothing bound to it may hold EarnShare (its Portal allowance is still warmed)`,
    )
  }
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
    // Deposit returns EarnShare to the Zone and Redeem returns the private asset.
    if (router.ops.includes('deposit')) warmUp(earnShare, 'EarnShare')
    if (router.ops.includes('redeem')) warmUp(router.earn.privateAsset, 'private asset')
  }
  for (const [label, token] of spendTokens) {
    seed(routerAddress, 'Zone router', token, label)
    warmUp(token, label)
  }

  const factory = zoneRouterFactory(profile, outputs)
  for (const spender of spends ? (router.spenders ?? []) : []) {
    // A card program's units follow its own runbook, so nothing is sent to it here; it must still be
    // a program the release CardFactory deployed for this router factory.
    if (await isCardProgram(client, spender)) {
      unverified.push(
        ...(await spenderProvenanceBlockers(client, { factory, spenders: [spender] }, releases)),
      )
      continue
    }
    const release = await releaseSendSpender(client, { factory, spender }, releases)
    if ('blocker' in release) {
      unverified.push(release.blocker)
      continue
    }
    const label = 'SendSpender ' + spender
    for (const [tokenLabel, token] of spendTokens) seed(spender, label, token, tokenLabel)
    // An EarnShare spend redeems here when it converts or pays a virtual address.
    if (spendTokens.some(([, token]) => token === earnShare))
      seed(spender, label, asset, 'vault asset')
    // Only a spend of the bound vault's EarnShare reaches the conversion branch.
    if (
      release.convertVault === zeroAddress ||
      !spendTokens.some(([, token]) => token === earnShare) ||
      getAddress(release.convertVault) !== getAddress(earnVault)
    )
      continue
    for (const functionName of ['convertAsset', 'parToken'] as const) {
      const value: unknown = await client
        .readContract({ address: spender, abi: sendSpenderAbi, functionName })
        .catch(missingGetter)
      if (typeof value !== 'string' || !isAddress(value)) continue
      if (getAddress(value) === zeroAddress) continue
      const tokenLabel = known.get(getAddress(value))
      if (tokenLabel) seed(spender, label, getAddress(value), tokenLabel)
      // A token outside the stack, such as another par stablecoin, is never sent automatically.
      else
        notes.push(
          `${label} ${functionName} ${getAddress(value)} is not one of the profile's tokens, so it is not seeded: send it 1 base unit by hand if wanted`,
        )
    }
  }
  // A router release that sets its Portal allowance per callback refuses warm with OpDisabled (a router
  // without Spend), so only allowances the router can keep standing are planned. Any other refusal
  // stays planned, so the step hands it off rather than reporting the router warmed.
  const refusals = await Promise.all(
    warm.map((entry) =>
      simulationRefusal(client, profile.deployer, {
        to: routerAddress,
        data: encodeFunctionData({ abi: zoneRouterAbi, functionName: 'warm', args: [entry.token] }),
      }),
    ),
  )
  const perCallback = refusals.map((refusal) => refusal !== undefined && refusal.disabled)
  refusals.forEach((refusal, index) => {
    if (refusal === undefined) return
    const entry = warm[index]!
    notes.push(
      perCallback[index]
        ? `Zone router ${routerAddress} refuses warm(${entry.token}) (${refusal.reason}), so its ${entry.tokenLabel} Portal allowance is set per callback and not warmed`
        : `Zone router ${routerAddress} reverts warm(${entry.token}) (${refusal.reason}), so its ${entry.tokenLabel} Portal allowance cannot be set and returns of that token to the Zone may fail`,
    )
  })
  return {
    router: routerAddress,
    portal,
    seeds,
    warm: warm.filter((_, index) => !perCallback[index]),
    unverified,
    notes,
  }
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

/** Whether the router holds every Portal allowance it returns funds through. Anyone may warm one. */
export function zoneRouterWarmed(missing: MissingZoneRouterSeeds) {
  return missing.warm.length === 0
}

/**
 * One note per unverified spender and per missing seed or warm-up, naming the transfer or call that
 * fixes it.
 */
export function zoneRouterSeedNotes(plan: ZoneRouterSeedPlan, missing: MissingZoneRouterSeeds) {
  return [
    ...plan.unverified.map((blocker) => blocker + ', so seed-zone-router sends it nothing'),
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

/**
 * The calls that fix what is missing, each with what it does: a 1-unit transfer per seed (with the token
 * it spends) and one warm call per token.
 */
export function zoneRouterSeedCalls(
  plan: ZoneRouterSeedPlan,
  missing: MissingZoneRouterSeeds,
): { description: string; spends?: Address; to: Address; data: Hex }[] {
  return [
    ...missing.seeds.map((entry) => ({
      description: `1 base unit of ${entry.tokenLabel} ${entry.token} to ${entry.holderLabel} ${entry.holder}`,
      spends: entry.token,
      to: entry.token,
      data: encodeFunctionData({
        abi: erc20Abi,
        functionName: 'transfer',
        args: [entry.holder, 1n],
      }),
    })),
    ...missing.warm.map((entry) => ({
      description: `warm(${entry.token}) on Zone router ${plan.router} for ${entry.tokenLabel}`,
      to: plan.router,
      data: encodeFunctionData({ abi: zoneRouterAbi, functionName: 'warm', args: [entry.token] }),
    })),
  ]
}

/** The seed calls the deployer can send now, and why each other one is left for someone else. */
export type SendableZoneRouterSeedCalls = {
  calls: { to: Address; data: Hex }[]
  refused: string[]
}

/**
 * Splits the calls that fix what is missing into those `account` can send and those it cannot: any
 * call that reverts when simulated from it (a TIP-403 transfer policy refusing it or the holder, say),
 * so one refusal never reverts the batch, then transfers past what it holds of each token, in order.
 * Other RPC errors throw; only the chain's refusal is a reason to leave a call.
 */
export async function sendableZoneRouterSeedCalls(
  client: Pick<PublicClient, 'call' | 'readContract'>,
  account: Address,
  plan: ZoneRouterSeedPlan,
  missing: MissingZoneRouterSeeds,
): Promise<SendableZoneRouterSeedCalls> {
  const calls = zoneRouterSeedCalls(plan, missing)
  const tokens = [...new Set(calls.flatMap((call) => (call.spends ? [call.spends] : [])))]
  const held = new Map(
    await Promise.all(
      tokens.map(
        async (token) =>
          [
            token,
            await client.readContract({
              address: token,
              abi: erc20Abi,
              functionName: 'balanceOf',
              args: [account],
            }),
          ] as const,
      ),
    ),
  )
  const tooLittle = (call: (typeof calls)[number]) =>
    `${call.description}: the deployer ${account} holds too little of the token`
  const simulated = await Promise.all(
    calls.map(async (call): Promise<string | undefined> => {
      if (call.spends && held.get(call.spends)! === 0n) return tooLittle(call)
      const refusal = await simulationRefusal(client, account, call)
      return refusal === undefined
        ? undefined
        : `${call.description}: reverts from the deployer ${account} (${refusal.reason})`
    }),
  )
  // Each transfer spends 1 base unit, so what the deployer holds funds the first transfers that pass.
  const budget = new Map(held)
  const outcomes = calls.map((call, index) => {
    if (simulated[index] !== undefined || !call.spends) return simulated[index]
    const left = budget.get(call.spends)!
    if (left === 0n) return tooLittle(call)
    budget.set(call.spends, left - 1n)
    return undefined
  })
  return {
    calls: calls
      .filter((_, index) => outcomes[index] === undefined)
      .map(({ to, data }) => ({ to, data })),
    refused: outcomes.filter((outcome) => outcome !== undefined),
  }
}

/**
 * Why `call` reverts when `account` sends it alone, or undefined when it would succeed. Only an
 * execution revert counts; rate limits, transport and other node errors throw.
 */
async function simulationRefusal(
  client: Pick<PublicClient, 'call'>,
  account: Address,
  call: { to: Address; data: Hex },
) {
  try {
    await client.call({ account, to: call.to, data: call.data })
    return undefined
  } catch (error) {
    if (
      !(error instanceof BaseError) ||
      error.walk((cause) => cause instanceof ExecutionRevertedError) === null
    )
      throw error
    // Nodes return the revert data on the RPC error; some also name the error in the message.
    const data = error.walk((cause) => typeof (cause as { data?: unknown }).data === 'string') as {
      data?: string
    } | null
    const disabled =
      data?.data?.toLowerCase().startsWith(opDisabledSelector) === true ||
      error.message.includes('OpDisabled')
    return { disabled, reason: error.shortMessage }
  }
}

/** The ZoneRouter's `OpDisabled()` error selector. */
const opDisabledSelector = toFunctionSelector('OpDisabled()')
