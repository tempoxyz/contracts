import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { concatHex, isHex, zeroAddress, type Address, type Hex, type PublicClient } from 'viem'

import {
  assertFoundryProjectEnvironment,
  foundryVerificationEnvironment,
} from '../../../chain/foundry.js'

const repository = fileURLToPath(new URL('../../../../', import.meta.url))
const builds = new Map<string, Hex>()

type Contract =
  | { project: 'earn'; contract: 'src/router/SingleZoneEarnRouter.sol:SingleZoneEarnRouter' }
  | {
      project: 'zone-router'
      contract: 'src/ZoneRouter.sol:ZoneRouter' | 'src/ZoneRouterFactory.sol:ZoneRouterFactory'
    }

/**
 * Requires exact runtime from the reviewed constructor before granting independent authority.
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
    actual.toLowerCase() !== expected.data.toLowerCase()
  )
    throw new Error(
      `Router admission requires canonical implementation provenance for ${options.address} (${options.contract})`,
    )
}

function compiledCreation(options: Contract): Hex {
  const key = `${options.project}:${options.contract}`
  const cached = builds.get(key)
  if (cached) return cached
  const root = `${repository}${options.project}`
  assertFoundryProjectEnvironment(root)
  const code = execFileSync('forge', ['inspect', options.contract, 'bytecode'], {
    cwd: root,
    encoding: 'utf8',
    env: foundryVerificationEnvironment(process.env),
  }).trim()
  if (!isHex(code) || code === '0x')
    throw new Error(`Invalid canonical creation code for ${options.contract}`)
  builds.set(key, code)
  return code
}
