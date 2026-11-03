import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

import {
  concatHex,
  encodeAbiParameters,
  getAddress,
  getContractAddress,
  isHex,
  keccak256,
  parseAbiParameters,
  stringToBytes,
  type Hex,
} from 'viem'

import { foundryVerificationEnvironment } from '../../chain/foundry.js'
import type { SpenderReleases } from './inspection.js'

const repository = fileURLToPath(new URL('../../../', import.meta.url))
const creationCodes = new Map<string, Hex>()
// DeterministicRelease's CREATE2 deployer and `RELEASE_SALT`, as the release scripts use them.
const create2Deployer = getAddress('0x4e59b44847b379578588920cA78FbF26c0B4956C')
const releaseSalt = keccak256(stringToBytes('tempoxyz/earn shared factory release'))

/**
 * A contract's creation code as its project's release builds it: the Zone router's under its `deploy`
 * profile (`pnpm zone-router-release`), the card project's under its default one (its release.sh).
 */
function creationCode(project: 'cards' | 'zone-router', contract: string) {
  const key = `${project}:${contract}`
  const cached = creationCodes.get(key)
  if (cached) return cached
  const environment = foundryVerificationEnvironment(process.env)
  if (project === 'cards') delete environment.FOUNDRY_PROFILE
  const bytecode = execFileSync('forge', ['inspect', contract, 'bytecode'], {
    cwd: `${repository}${project}`,
    encoding: 'utf8',
    env: environment as NodeJS.ProcessEnv,
  }).trim()
  if (!isHex(bytecode) || bytecode === '0x') {
    throw new Error(`Forge returned invalid creation bytecode for ${contract}`)
  }
  creationCodes.set(key, bytecode)
  return bytecode
}

/** A release contract's address: created through the CREATE2 deployer with the release salt. */
const releaseAddress = (initCode: Hex) =>
  getContractAddress({
    opcode: 'CREATE2',
    from: create2Deployer,
    salt: releaseSalt,
    bytecode: initCode,
  })

/** The release addresses of this checkout's builds, which inspection compares each listed spender with. */
export const spenderReleases: SpenderReleases = {
  cardFactory: (routerFactory) =>
    releaseAddress(
      concatHex([
        creationCode('cards', 'src/core/CardFactory.sol:CardFactory'),
        encodeAbiParameters(parseAbiParameters('address'), [routerFactory]),
      ]),
    ),
  sendSpender: ({ routerFactory, convertVault, pool, customerId }) =>
    releaseAddress(
      concatHex([
        creationCode('zone-router', 'src/spenders/SendSpender.sol:SendSpender'),
        encodeAbiParameters(parseAbiParameters('address, address, address, bytes32'), [
          routerFactory,
          convertVault,
          pool,
          customerId,
        ]),
      ]),
    ),
}
