import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { concatHex, isHex, zeroAddress, type Address, type Hex, type PublicClient } from 'viem'

import {
  assertFoundryProjectEnvironment,
  foundryVerificationEnvironment,
} from '../../../chain/foundry.js'
import { stripMetadata } from '../../../core/releases.js'

const repository = fileURLToPath(new URL('../../../../', import.meta.url))
const builds = new Map<string, Hex>()

type Contract = {
  contract:
    | 'src/earn/router/SingleZoneEarnRouter.sol:SingleZoneEarnRouter'
    | 'src/zone/ZoneRouter.sol:ZoneRouter'
    | 'src/zone/ZoneRouterFactory.sol:ZoneRouterFactory'
}

/**
 * Requires the reviewed constructor's runtime before granting independent authority: every byte,
 * immutables included, apart from compiler metadata, which replacement ignores too.
 * Contract-creation eth_call is read-only and includes every constructor-bound immutable, not masked slots.
 */
export async function requireRouterProvenance(
  client: Pick<PublicClient, 'call' | 'getCode'>,
  options: Contract & { address: Address; constructorArgs: Hex },
  compile: (options: Contract) => Hex = compiledCreation,
) {
  const initCode = concatHex([compile(options), options.constructorArgs])
  const [actual, expected] = await Promise.all([
    client.getCode({ address: options.address }),
    // No destination means constructor simulation, never a transaction or a verifier submission.
    client.call({ account: zeroAddress, data: initCode }),
  ])
  if (
    !actual ||
    actual === '0x' ||
    !expected.data ||
    expected.data === '0x' ||
    stripMetadata(actual.toLowerCase() as Hex) !== stripMetadata(expected.data.toLowerCase() as Hex)
  )
    throw new ProvenanceMismatchError(
      `Router admission requires canonical implementation provenance for ${options.address} (${options.contract})`,
    )
}

/** The deployed runtime is not this build's; matched by `name`, so callers need not import the class. */
export class ProvenanceMismatchError extends Error {
  override name = 'ProvenanceMismatchError'
}

function compiledCreation(options: Contract): Hex {
  const cached = builds.get(options.contract)
  if (cached) return cached
  const root = repository
  assertFoundryProjectEnvironment(root)
  const code = execFileSync('forge', ['inspect', options.contract, 'bytecode'], {
    cwd: root,
    encoding: 'utf8',
    env: foundryVerificationEnvironment(process.env),
  }).trim()
  if (!isHex(code) || code === '0x')
    throw new Error(`Invalid canonical creation code for ${options.contract}`)
  builds.set(options.contract, code)
  return code
}
