import { vedaTellerAbi } from '@tempoxyz/earn/abis'
import {
  InspectionMismatchError,
  inspectVedaPeriphery,
  vedaPeriphery,
  type PublicEarnStack,
} from '@tempoxyz/earn/deployments'
import { getAddress, type Address, type PublicClient, zeroAddress } from 'viem'

type Client = Pick<PublicClient, 'readContract'>
type Deployment = PublicEarnStack

/**
 * Verifies the Veda engine's periphery wiring and Teller capabilities through the shared inspector,
 * then that the periphery it reports is the one the catalog records and that the Teller accepts the
 * EarnVault asset. Queue capabilities are out of scope: the browser does not implement queued exits.
 */
export async function verify(client: Client, deployment: Deployment, issues: string[]) {
  const veda = vedaPeriphery(deployment.contracts)
  let periphery: Awaited<ReturnType<typeof inspectVedaPeriphery>>
  try {
    periphery = await inspectVedaPeriphery(client, deployment.contracts.engine)
  } catch (error) {
    if (!(error instanceof InspectionMismatchError)) throw error
    issues.push(`Veda engine wiring does not verify: ${error.message}.`)
    return
  }
  compareAddress(
    issues,
    'VedaEngine periphery registry does not match the registry.',
    veda.peripheryRegistry,
    periphery.registry,
  )
  compareAddress(
    issues,
    'VedaEngine Accountant does not match the registry.',
    veda.accountant,
    periphery.accountant,
  )
  compareAddress(
    issues,
    'VedaEngine Queue does not match the registry.',
    veda.queue ?? zeroAddress,
    periphery.queue,
  )
  compareAddress(
    issues,
    'VedaEngine Teller does not match the registry.',
    veda.teller,
    periphery.teller,
  )
  compareAddress(
    issues,
    'Veda BoringVault RolesAuthority does not match the registry.',
    veda.rolesAuthority,
    periphery.authority,
  )

  const [allowsBaseDeposits, , baseAssetSharePremium] = await client.readContract({
    address: periphery.teller,
    abi: vedaTellerAbi,
    functionName: 'assetData',
    args: [deployment.contracts.asset],
  })
  if (!allowsBaseDeposits || baseAssetSharePremium > 10_000) {
    issues.push('Veda Teller has an unsupported EarnVault asset deposit configuration.')
  }
}

function compareAddress(issues: string[], message: string, expected: Address, actual: Address) {
  if (getAddress(actual) !== expected) issues.push(message)
}
