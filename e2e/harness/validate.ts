import { demoStablecoinFunderAbi, earnVaultAbi } from '@tempoxyz/contracts/abis'
import { engineDefinitions } from '@tempoxyz/contracts/deployments'
import {
  inspectEarnDeployment,
  type EarnDeploymentRecord,
} from '@tempoxyz/contracts/deployments/node'
import {
  optionalPeriphery,
  parseWhitelistPolicy,
  requiredAccessMembers,
  validateEarnShareWhitelist,
  type EarnDeploymentProfile,
} from '@tempoxyz/contracts/deployments/operations'
import { erc20Abi, getAddress, isAddress, type Address, type PublicClient } from 'viem'
import { Abis } from 'viem/tempo'
import type { DeploymentPublicClient, E2eStack } from './context.js'
import { moduleValidators } from './modules.js'
import type { StablecoinFixture } from '../fixtures/profile-fixture.js'
import { assert } from './support/utils.js'

const ERC1967_IMPLEMENTATION_SLOT =
  '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc' as const

/**
 * The read-only checks every run passes before it signs anything. A hosted run first repeats the
 * shared deployment inspection against its profile's record and requires what that inspection only
 * reports: a ready engine and capabilities, exclusive EarnShare issuance, aligned accounting, and
 * every required TIP-403 member; localnet already verified the stacks it deploys. E2E then adds
 * what its cases assume: EarnVault custody at rest, the fixture funder's issuer roles, and each
 * capability module's own checks.
 */
export async function validateDeployment(
  client: DeploymentPublicClient,
  deployment: E2eStack,
  hosted?: { profile: EarnDeploymentProfile; record: EarnDeploymentRecord },
) {
  if (hosted) await validateHostedDeployment(client, deployment, hosted)
  await validateCustodyAtRest(client, deployment)
  const fixture = deployment.stablecoinFixture
  if (fixture?.funder) await validateFixtureFunder(client, fixture, fixture.funder)
  for (const validate of moduleValidators) await validate(client, deployment)
}

async function validateHostedDeployment(
  client: DeploymentPublicClient,
  deployment: E2eStack,
  hosted: { profile: EarnDeploymentProfile; record: EarnDeploymentRecord },
) {
  const { contracts, operations } = deployment
  const report = await inspectEarnDeployment(
    client,
    hosted.profile,
    hosted.record.addresses as Record<string, Address>,
    hosted.record.source.factoryDeploymentId,
  )
  const blocked = Object.values(report).filter(({ status }) => status !== 'ready')
  assert(
    blocked.length === 0,
    `deployment is not ready: ${blocked.map(({ label, blockers }) => `${label}: ${blockers.join('; ')}`).join(', ')}`,
  )
  // The shared inspection checks engine bindings; acceptance also needs deposits to be open.
  await engineDefinitions[deployment.engineKind].inspectBindings?.(
    client,
    contracts.engine,
    'ready',
  )

  const implementationSlot = await client.getStorageAt({
    address: contracts.earnVault,
    slot: ERC1967_IMPLEMENTATION_SLOT,
  })
  assert(implementationSlot !== undefined, 'EarnVault implementation slot is empty')
  const implementation = getAddress(`0x${implementationSlot.slice(-40)}`)
  const implementationCode = await client.getCode({ address: implementation })
  assert(
    implementationCode !== undefined && implementationCode !== '0x',
    'EarnVault proxy implementation has no contract code',
  )

  // The shared inspection proved EarnVault issues EarnShare; no other known contract may.
  const others = [
    operations.owner,
    operations.factory,
    ...Object.values(optionalPeriphery(operations)),
    ...Object.values(contracts.periphery ?? {}),
    ...Object.entries(contracts).flatMap(([key, value]) =>
      typeof value === 'string' &&
      isAddress(value) &&
      !['asset', 'earnShare', 'earnVault'].includes(key)
        ? [value]
        : [],
    ),
  ]
  const issuerRole = await client.readContract({
    address: contracts.earnShare,
    abi: Abis.tip20,
    functionName: 'ISSUER_ROLE',
  })
  const [aligned, ...issuers] = await Promise.all([
    client.readContract({
      address: contracts.earnVault,
      abi: earnVaultAbi,
      functionName: 'isAccountingAligned',
    }),
    ...others.map((account) =>
      client.readContract({
        address: contracts.earnShare,
        abi: Abis.tip20,
        functionName: 'hasRole',
        args: [account, issuerRole],
      }),
    ),
  ])
  assert(aligned, 'EarnVault accounting is not aligned')
  assert(!issuers.some(Boolean), 'a contract other than EarnVault holds the EarnShare issuer role')

  if (deployment.access.kind !== 'open') {
    await validateEarnShareWhitelist(client, {
      earnShare: contracts.earnShare,
      policyId: parseWhitelistPolicy(deployment.access),
      requiredMembers: await requiredAccessMembers(client, deployment),
    })
  }
}

/** EarnVault holds neither vault assets nor venue shares between actions. */
async function validateCustodyAtRest(client: DeploymentPublicClient, deployment: E2eStack) {
  const { contracts } = deployment
  const [vaultAssets, vaultVenueShares] = await Promise.all(
    [contracts.asset, contracts.venue].map((token) =>
      client.readContract({
        address: token,
        abi: erc20Abi,
        functionName: 'balanceOf',
        args: [contracts.earnVault],
      }),
    ),
  )
  assert(vaultAssets === 0n, 'EarnVault retains vault assets at rest')
  assert(vaultVenueShares === 0n, 'EarnVault retains venue shares at rest')
}

/** A fixture funder mints exactly the fixture pair it claims to fund. */
async function validateFixtureFunder(
  client: Pick<PublicClient, 'readContract'>,
  fixture: StablecoinFixture,
  funderAddress: Address,
) {
  const funder = { address: funderAddress, abi: demoStablecoinFunderAbi } as const
  const [baseAsset, alternateAsset, ...issuers] = await Promise.all([
    client.readContract({ ...funder, functionName: 'baseAsset' }),
    client.readContract({ ...funder, functionName: 'alternateAsset' }),
    ...[fixture.baseAsset, fixture.alternateAsset].map(async (token) =>
      client.readContract({
        address: token,
        abi: Abis.tip20,
        functionName: 'hasRole',
        args: [
          funderAddress,
          await client.readContract({
            address: token,
            abi: Abis.tip20,
            functionName: 'ISSUER_ROLE',
          }),
        ],
      }),
    ),
  ])
  assert(getAddress(baseAsset) === fixture.baseAsset, 'funder base asset mismatch')
  assert(getAddress(alternateAsset) === fixture.alternateAsset, 'funder alternate asset mismatch')
  assert(issuers.every(Boolean), 'funder is missing ISSUER_ROLE on a fixture token')
}
