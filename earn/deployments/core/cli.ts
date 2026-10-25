#!/usr/bin/env node
import { existsSync, readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseArgs } from 'node:util'

import { formatUnits } from 'viem'

import { capabilityCommands } from '../modules/commands.js'
import {
  capabilityModules,
  deploymentStep,
  provenSigners,
  type EarnDeploymentActionId,
} from '../modules/index.js'
import { deployEarnProfile, verifyEarnProfile } from './deploy.js'
import type { InspectionReport } from '../modules/module.js'
import { depositEarnProfile, type ProfileDepositResult } from './deposit.js'
import { loadPendingDeployment } from './pending.js'
import { activationActions, presentEarnDeploymentPlan } from './plan.js'
import { deploymentIntentHash } from './profile.js'
import { rpcConfiguration } from '../chain/runtime.js'
import {
  loadDeploymentEnvironment,
  loadEarnProfile,
  loadEarnProfileBundle,
  loadEarnProfileForEnvironment,
  loadProfileDeploymentRecord,
  profileDeploymentPath,
  profileRepositoryRoot,
  resolveProfilePath,
} from './bundle.js'

/** `verify --skip-<flag>` for each module's live check of an external chain. */
const skipLiveFlags = capabilityModules.flatMap((module) =>
  module.liveCheck ? [module.liveCheck.flag] : [],
)

const usage =
  'Usage: pnpm earn <plan|deploy|status|verify|deposit> <profile.json> [--rpc-url <url>] [--watch] [--json]\n' +
  `       pnpm earn verify <profile.json> ${skipLiveFlags.map((flag) => `[--skip-${flag}]`).join(' ')} [--rpc-url <url>] [--json]\n` +
  '       pnpm earn deposit <profile.json> --assets <amount> [--account <address>] [--receiver <address>] [--slippage-bps <bps>] [--broadcast] [--rpc-url <url>] [--json]\n' +
  capabilityCommands.map((command) => `       ${command.usage.replace('Usage: ', '')}`).join('\n')

type Command = 'deploy' | 'deposit' | 'plan' | 'status' | 'verify'
type Output = Pick<Console, 'log' | 'warn'>

/** Testable CLI boundary for the shared profile lifecycle and guarded operational helpers. */
export async function main(
  argv: string[] = process.argv.slice(2),
  output: Output = console,
  repositoryRoot = resolve(fileURLToPath(new URL('../..', import.meta.url))),
) {
  const help = argv.includes('--help') || argv.includes('-h')
  const capabilityCommand = capabilityCommands.find((command) => command.name === argv[0])
  if (capabilityCommand) {
    if (help) output.log(capabilityCommand.usage)
    else await capabilityCommand.run(argv.slice(1), output)
    return
  }
  if (help) {
    output.log(usage)
    return
  }

  const [command, input, ...rawArguments] = argv
  if (!input || !isCommand(command)) throw new Error(usage)
  const options = parseArguments(command, rawArguments)

  const profilePath = resolveProfilePath(input)
  const authoredProfile = JSON.parse(readFileSync(profilePath, 'utf8')) as unknown
  const preliminaryProfile = loadEarnProfile(profilePath)
  const recorded = existsSync(profileDeploymentPath(profilePath))
  const environment = loadDeploymentEnvironment(
    profileRepositoryRoot(profilePath),
    preliminaryProfile.id,
    process.env,
    [
      // Without a record, the deployer key resolves the deterministic deployment identity.
      ...(recorded ? [] : ['DEPLOYER_PRIVATE_KEY']),
      ...(command === 'plan' || command === 'status' || options.rpcUrl ? [] : ['TEMPO_RPC_URL']),
    ],
  )
  const profile = environment.DEPLOYER_PRIVATE_KEY
    ? loadEarnProfileForEnvironment(profilePath, environment)
    : loadEarnProfileBundle(profilePath).profile

  if (command === 'plan') {
    const configuredRpc = rpcConfiguration('TEMPO', environment)
    const rpcUrl = options.rpcUrl ?? configuredRpc.authenticatedUrl
    const proven = rpcUrl ? await provenSigners({ environment, profile, rpcUrl }) : new Set<never>()
    print(
      {
        state: 'planned',
        deploymentId: profile.id,
        deploymentIntentHash: deploymentIntentHash(profile),
        profile: authoredProfile,
        resolved: {
          deployer: profile.deployer,
          owner: profile.owner,
          factories: profile.factories,
        },
        actions: presentEarnDeploymentPlan(profile, environment, proven),
      },
      options.json,
      output,
    )
    return
  }

  if (command === 'status') {
    const recordPath = profileDeploymentPath(profilePath)
    if (existsSync(recordPath)) {
      const record = loadProfileDeploymentRecord(profilePath, profile)
      const activation = activationActions(profile).map((action) => action.id)
      const sourceVerificationPending = record.source.contractVerification === 'pending'
      print(
        {
          state: sourceVerificationPending
            ? 'verification-pending'
            : activation.length === 0
              ? 'complete'
              : 'deployed',
          deploymentId: profile.id,
          deploymentIntentHash: record.deploymentIntentHash,
          recordPath,
          addresses: record.addresses,
          sourceVerification: record.source.contractVerification,
          ...(sourceVerificationPending
            ? { instructions: 'Re-run the deploy command to complete source verification.' }
            : {}),
          ...(activation.length === 0
            ? {}
            : { activation: { state: 'unchecked', actions: activation } }),
        },
        options.json,
        output,
      )
    } else {
      const pending = loadPendingDeployment(profilePath, profile)
      print(
        {
          state: Object.keys(pending.actions).length === 0 ? 'not-started' : 'in-progress',
          deploymentId: profile.id,
          deploymentIntentHash: pending.deploymentIntentHash,
          completedActions: Object.keys(pending.actions),
          addresses: pending.outputs,
        },
        options.json,
        output,
      )
    }
    return
  }

  const configuredRpc = rpcConfiguration('TEMPO', environment)
  const rpcUrl = options.rpcUrl ?? configuredRpc.authenticatedUrl
  if (!rpcUrl) throw new Error('--rpc-url or TEMPO_RPC_URL is required')

  if (command === 'verify') {
    const { record, readiness, capabilityReadiness, unverified } = await verifyEarnProfile({
      environment,
      profilePath,
      root: repositoryRoot,
      rpcUrl,
      skipLive: options.skipLive,
    })
    print(
      {
        state: 'verified',
        readiness,
        capabilityReadiness,
        unverified,
        deploymentId: profile.id,
        deploymentIntentHash: record.deploymentIntentHash,
        recordPath: profileDeploymentPath(profilePath),
      },
      options.json,
      output,
    )
    return
  }

  if (command === 'deposit') {
    const record = loadProfileDeploymentRecord(profilePath, profile)
    const result = await depositEarnProfile({
      account: options.account,
      assets: options.assets!,
      broadcast: options.broadcast,
      environment,
      profile,
      receiver: options.receiver,
      record,
      rpcUrl,
      slippageBps: options.slippageBps,
    })
    print(result, options.json, output)
    return
  }

  for (;;) {
    const result = await deployEarnProfile({
      environment,
      profilePath,
      root: repositoryRoot,
      rpcUrl,
    })
    if (result.state === 'complete' || result.state === 'verification-pending') {
      print(
        {
          state: result.state,
          deploymentId: profile.id,
          deploymentIntentHash: result.deploymentIntentHash,
          recordPath: result.recordPath,
          addresses: result.addresses,
          ...(result.state === 'complete'
            ? { capabilityReadiness: result.capabilityReadiness }
            : {}),
          ...(result.state === 'verification-pending' ? { instructions: result.instructions } : {}),
        },
        options.json,
        output,
      )
      return
    }
    print(
      {
        state: result.state,
        deploymentId: profile.id,
        deploymentIntentHash: result.deploymentIntentHash,
        action: result.handoff.action.id,
        instructions: result.handoff.instructions,
        addresses: result.addresses,
        ...(result.recordPath ? { recordPath: result.recordPath } : {}),
        ...(result.sourceVerification
          ? {
              sourceVerification: result.sourceVerification,
              verificationInstructions: result.verificationInstructions,
            }
          : {}),
      },
      options.json,
      output,
    )
    if (!options.watch) return
    if (!options.json) output.log('Watching chain state; press Ctrl-C to stop safely.')
    await new Promise((resolveDelay) => setTimeout(resolveDelay, 15_000))
  }
}

function parseArguments(command: Command, args: string[]) {
  const { values } = parseArgs({
    args,
    options: {
      'rpc-url': { type: 'string' },
      watch: { type: 'boolean', default: false },
      json: { type: 'boolean', default: false },
      account: { type: 'string' },
      assets: { type: 'string' },
      broadcast: { type: 'boolean', default: false },
      receiver: { type: 'string' },
      'slippage-bps': { type: 'string' },
      ...Object.fromEntries(
        skipLiveFlags.map((flag) => [`skip-${flag}`, { type: 'boolean', default: false } as const]),
      ),
    },
  })
  // An empty value (for example an unset shell variable) must not read as an omitted option.
  for (const [flag, value] of Object.entries(values))
    if (value === '') throw new Error(`--${flag} requires a value`)
  const { 'rpc-url': rpcUrl, watch, json, account, assets, broadcast, receiver } = values
  const slippage = values['slippage-bps']
  const slippageBps = slippage === undefined ? undefined : Number(slippage)
  if (slippageBps !== undefined && !Number.isInteger(slippageBps))
    throw new Error('--slippage-bps must be an integer')
  if (command !== 'deploy' && watch) throw new Error('--watch is supported only by deploy')
  if (
    command !== 'deposit' &&
    (account || assets || broadcast || receiver || slippageBps !== undefined)
  ) {
    throw new Error('Deposit flags are supported only by deposit')
  }
  if (command === 'deposit' && !assets) throw new Error('--assets is required by deposit')
  const skipLive = skipLiveFlags.filter(
    (flag) => (values as Record<string, unknown>)[`skip-${flag}`],
  )
  if (command !== 'verify' && skipLive.length > 0)
    throw new Error(`--skip-${skipLive[0]} is supported only by verify`)
  return { account, assets, broadcast, receiver, rpcUrl, skipLive, slippageBps, watch, json }
}

function print(
  value: Record<string, unknown> | ProfileDepositResult,
  json: boolean,
  output: Output,
) {
  if (json) {
    output.log(JSON.stringify(value, null, 2))
    return
  }
  if (value.state === 'complete') {
    const deployment = value as Record<string, unknown>
    output.log(`Earn deployment ${deployment.deploymentId} is reconciled.`)
    output.log(`Commit-ready deployment result: ${deployment.recordPath}`)
    printCapabilityReadiness(deployment.capabilityReadiness, output)
    return
  }
  if (value.state === 'verified') {
    output.log(`Earn deployment record ${value.deploymentId} is verified onchain.`)
    if ('readiness' in value && value.readiness) {
      const readiness = value.readiness as {
        status: string
        blockers: string[]
        warnings: string[]
      }
      output.log(`Engine deposit readiness: ${readiness.status}`)
      for (const message of [...readiness.blockers, ...readiness.warnings])
        output.log(`  ${message}`)
    }
    printCapabilityReadiness((value as Record<string, unknown>).capabilityReadiness, output)
    for (const label of (value as { unverified: string[] }).unverified)
      output.log(`${label}: not verified`)
    return
  }
  if (value.state === 'deployed') {
    const deployment = value as Record<string, unknown>
    output.log(`Earn deployment ${deployment.deploymentId} is deployed.`)
    output.log(`Commit-ready deployment result: ${deployment.recordPath}`)
    output.log(
      'Post-deployment activation has not been checked; run the deploy command to reconcile it.',
    )
    return
  }
  if (value.state === 'handoff') {
    const handoff = value as Record<string, unknown>
    if (handoff.recordPath) output.log(`Commit-ready deployment result: ${handoff.recordPath}`)
    const { authority } = deploymentStep(handoff.action as EarnDeploymentActionId)
    output.log(`${handoff.action} requires the ${authority.label}. ${handoff.instructions}`)
    if (handoff.verificationInstructions) output.log(String(handoff.verificationInstructions))
    return
  }
  if (value.state === 'verification-pending') {
    const deployment = value as Record<string, unknown>
    output.log(`Earn deployment ${deployment.deploymentId} is recorded onchain.`)
    output.log(`Deployment result: ${deployment.recordPath}`)
    output.log(String(deployment.instructions))
    return
  }
  if (value.state === 'not-started') {
    output.log(`Earn deployment ${value.deploymentId} has not started.`)
    return
  }
  if (value.state === 'in-progress') {
    output.log(`Earn deployment ${value.deploymentId} is in progress.`)
    return
  }
  if (value.state === 'preview' || value.state === 'deposited') {
    const result = value as ProfileDepositResult
    output.log(
      `${result.state === 'preview' ? 'Deposit preview' : 'Deposit complete'} for ${result.deploymentId}.`,
    )
    output.log(`Depositor: ${result.depositor}`)
    output.log(`Receiver: ${result.receiver}`)
    output.log(
      `${formatUnits(BigInt(result.assets), result.asset.decimals)} ${result.asset.symbol} -> approximately ${formatUnits(BigInt(result.expectedEarnShares), result.earnShare.decimals)} ${result.earnShare.symbol}`,
    )
    output.log(
      `Minimum: ${formatUnits(BigInt(result.minimumEarnShares), result.earnShare.decimals)} ${result.earnShare.symbol} (${result.slippageBps} bps slippage)`,
    )
    output.log(
      `Current balance: ${formatUnits(BigInt(result.balanceBefore), result.asset.decimals)} ${result.asset.symbol}`,
    )
    if (result.state === 'preview') {
      output.log('No transaction submitted. Add --broadcast to execute this exact plan.')
      return
    }
    output.log(`Deposit transaction: ${result.depositTransactionHash}`)
    output.log(
      `EarnShare received: ${formatUnits(BigInt(result.depositedEarnShares!), result.earnShare.decimals)} ${result.earnShare.symbol}; accounting aligned: ${result.accountingAligned}`,
    )
    return
  }
  output.log(JSON.stringify(value, null, 2))
}

function isCommand(value: string | undefined): value is Command {
  return (
    value === 'deploy' ||
    value === 'deposit' ||
    value === 'plan' ||
    value === 'status' ||
    value === 'verify'
  )
}

if (resolve(process.argv[1] ?? '') === fileURLToPath(import.meta.url)) {
  try {
    await main()
  } catch (error) {
    // The lifecycle's own failures are plain errors naming the failed check and its remedy; any
    // other error keeps its stack.
    if (!(error instanceof Error) || error.constructor !== Error) throw error
    console.error(error.message)
    process.exitCode = 1
  }
}

/** Prints each capability's reported readiness: its status, details, and blockers. */
function printCapabilityReadiness(value: unknown, output: Output) {
  if (!value || typeof value !== 'object') return
  for (const readiness of Object.values(value as InspectionReport)) {
    output.log(`${readiness.label} readiness: ${readiness.status}`)
    for (const [key, detail] of Object.entries(readiness.details ?? {}))
      output.log(`  ${key}: ${detail ?? 'unknown'}`)
    for (const blocker of readiness.blockers) output.log(`  ${blocker}`)
  }
}
