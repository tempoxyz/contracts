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
 * A contract's creation code as its release builds it. Every profile compiles with the same
 * settings, so the Zone router's `deploy` build and the spend release script's default one agree.
 */
export function releaseCreationCode(contract: string) {
  const cached = creationCodes.get(contract)
  if (cached) return cached
  const bytecode = execFileSync('forge', ['inspect', contract, 'bytecode'], {
    cwd: repository,
    encoding: 'utf8',
    env: foundryVerificationEnvironment(process.env) as NodeJS.ProcessEnv,
  }).trim()
  if (!isHex(bytecode) || bytecode === '0x') {
    throw new Error(`Forge returned invalid creation bytecode for ${contract}`)
  }
  creationCodes.set(contract, bytecode)
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
        releaseCreationCode('src/spend/CardFactory.sol:CardFactory'),
        encodeAbiParameters(parseAbiParameters('address'), [routerFactory]),
      ]),
    ),
  sendSpender: ({ routerFactory, convertVault, pool, customerId }) =>
    releaseAddress(
      concatHex([
        releaseCreationCode('src/zone/spenders/SendSpender.sol:SendSpender'),
        encodeAbiParameters(parseAbiParameters('address, address, address, bytes32'), [
          routerFactory,
          convertVault,
          pool,
          customerId,
        ]),
      ]),
    ),
}
