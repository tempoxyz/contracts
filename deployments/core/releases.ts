import { getAddress, keccak256, zeroAddress, type Address, type Hex, type PublicClient } from 'viem'
import { Addresses } from 'viem/tempo'

import { earnFactoryAbi } from '../abis/index.js'
import { hostedEnvironment, type HostedEnvironmentId } from '../chain/tempo.js'
import {
  engineFactories,
  type EngineFactory,
  type EngineFactoryKey,
} from '../modules/engines/index.js'
import {
  address,
  array,
  exactKeys,
  isBytes32,
  nonnegativeInteger,
  object,
  positiveInteger,
} from './parse.js'
import type { EarnDeploymentProfile } from './profile.js'

/**
 * One shared factory release: the EarnFactory plus, keyed by each engine's `factory.releaseKey`,
 * the engine factories it carries. Profiles, pending state, and committed records store it in this
 * shape, so the keys are stable serialized names.
 */
export type EarnFactoryRelease = { earn: Address } & Partial<Record<EngineFactoryKey, Address>>

const engineFactoryKeys = engineFactories.map((factory) => factory.releaseKey)

/** Every key a release may carry, in serialized order. */
const factoryReleaseKeys: readonly (keyof EarnFactoryRelease)[] = ['earn', ...engineFactoryKeys]

/**
 * The reviewed releases of one hosted network: the shared factory release every fresh profile
 * deployment uses, with every engine factory key (`null` while that factory has no reviewed release
 * there).
 */
type CanonicalReleases = {
  factories: { earn: Address } & Record<EngineFactoryKey, Address | null>
}

/** Every hosted network's reviewed releases; a new network or engine factory needs its entry. */
const canonicalReleases: Readonly<Record<HostedEnvironmentId, CanonicalReleases>> = {
  mainnet: {
    factories: {
      earn: getAddress('0x3085a8003f340cd51c72d9e1a1298cdafb171b02'),
      erc4626Engine: getAddress('0xd43D00981222a8db444A528E69f19E3cE5A7D2Ff'),
    },
  },
  moderato: {
    factories: {
      earn: getAddress('0x749a947811764a14CD17fE3C7BcC5c470e2Ac5cC'),
      erc4626Engine: getAddress('0x0d57c10249eb3a92b7d81bBA6221F80F2865448A'),
    },
  },
}

/** The reviewed releases of the hosted network on a chain ID. */
function chainReleases(chainId: number) {
  const environment = hostedEnvironment(chainId)
  return environment ? canonicalReleases[environment.id] : undefined
}

/** The current reviewed release of a canonical chain, carrying only its released engine factories. */
export function resolveEarnFactoryRelease(chainId: number): EarnFactoryRelease {
  const release = chainReleases(chainId)?.factories
  if (!release) throw new Error(`No reviewed factory release for chain ${chainId}`)
  return {
    earn: release.earn,
    ...Object.fromEntries(
      engineFactoryKeys.flatMap((key) => (release[key] === null ? [] : [[key, release[key]]])),
    ),
  }
}

/** Whether two releases name exactly the same factories. */
export function sameFactoryRelease(left: EarnFactoryRelease, right: EarnFactoryRelease) {
  return factoryReleaseKeys.every((key) => left[key] === right[key])
}

/**
 * Parses a release: `earn` and any engine factories, nothing else. Records and pending state accept
 * any nonzero address and normalize it; the public catalog passes a checksummed parser.
 */
export function parseFactoryRelease(
  value: unknown,
  path: string,
  parseAddress: (value: unknown, path: string) => Address = address,
): EarnFactoryRelease {
  const release = object(value, path)
  exactKeys(release, path, ['earn'], engineFactoryKeys)
  return {
    earn: parseAddress(release.earn, `${path}.earn`),
    ...Object.fromEntries(
      engineFactoryKeys.flatMap((key) =>
        release[key] === undefined ? [] : [[key, parseAddress(release[key], `${path}.${key}`)]],
      ),
    ),
  }
}

/** A release with every factory at the zero address, for profiles parsed without deployment identity. */
export function unresolvedFactoryRelease(): EarnFactoryRelease {
  return {
    earn: zeroAddress,
    ...Object.fromEntries(engineFactoryKeys.map((key) => [key, zeroAddress])),
  }
}

/** The address of one engine factory in a release; a release without it cannot provision the engine. */
export function engineFactoryAddress(release: EarnFactoryRelease, factory: EngineFactory) {
  const value = release[factory.releaseKey as EngineFactoryKey]
  if (!value) throw new Error(`Factory release has no ${factory.contract}`)
  return value
}

/** Runtime hashes of a release's core contracts, plus `<releaseKey>Factory` for an engine factory. */
export type SharedFactoryRuntimeCodeHashes = {
  earnFactory: { hash: Hex; immutableReferences: ImmutableReference[] }
  earnVaultImplementation: Hex
  earnFeesImplementation: Hex
} & { [Key in EngineFactoryKey as `${Key}Factory`]?: Hex }

type ImmutableReference = { start: number; length: number }

/** A compiled contract's deployed bytecode and the compiler-declared immutable slots in it. */
export type CompiledRuntimeCode = { bytecode: Hex; references: ImmutableReference[] }

/** The serialized runtime-hash key of an engine factory, `<releaseKey>Factory`. */
const factoryHashKey = <const Key extends string>(factory: { releaseKey: Key }) =>
  `${factory.releaseKey}Factory` as const

/** Optional runtime-hash keys of the engine factories a fresh deployment pins. */
const engineFactoryHashKeys = engineFactories.map(factoryHashKey)

/**
 * Hashes the deployed runtime of the current release contracts, compiled by `compile` from a
 * `<source>:<contract>` identifier, including the engine factory a profile provisions its engine
 * through.
 */
export function sharedFactoryRuntimeCodeHashes(
  compile: (contract: string) => CompiledRuntimeCode,
  engineFactory?: Pick<EngineFactory, 'contract' | 'releaseKey' | 'source'>,
): SharedFactoryRuntimeCodeHashes {
  const earnFactory = compile('src/core/EarnFactory.sol:EarnFactory')
  const hash = (contract: string) => keccak256(compile(contract).bytecode)
  return {
    earnFactory: {
      hash: keccak256(normalizeImmutableReferences(earnFactory.bytecode, earnFactory.references)),
      immutableReferences: earnFactory.references,
    },
    earnVaultImplementation: hash('src/core/EarnVault.sol:EarnVault'),
    earnFeesImplementation: hash('src/core/EarnFees.sol:EarnFees'),
    ...(engineFactory
      ? {
          [factoryHashKey(engineFactory)]: hash(
            `${engineFactory.source}:${engineFactory.contract}`,
          ),
        }
      : {}),
  }
}

/** Parses release runtime hashes pinned in pending state. */
export function parseFactoryRuntimeCodeHashes(
  value: unknown,
  path: string,
): SharedFactoryRuntimeCodeHashes {
  const hashes = object(value, path)
  exactKeys(
    hashes,
    path,
    ['earnFactory', 'earnVaultImplementation', 'earnFeesImplementation'],
    engineFactoryHashKeys,
  )
  const earnFactory = object(hashes.earnFactory, `${path}.earnFactory`)
  exactKeys(earnFactory, `${path}.earnFactory`, ['hash', 'immutableReferences'])
  const bytes32 = (key: string, field: unknown = hashes[key]) => {
    if (!isBytes32(field)) throw new Error(`${path}.${key} must be a bytes32 hash`)
    return field
  }
  return {
    earnFactory: {
      hash: bytes32('earnFactory.hash', earnFactory.hash),
      immutableReferences: array(
        earnFactory.immutableReferences,
        `${path}.earnFactory.immutableReferences`,
      ).map((entry, index) => {
        const at = `${path}.earnFactory.immutableReferences.${index}`
        const reference = object(entry, at)
        exactKeys(reference, at, ['start', 'length'])
        return {
          start: nonnegativeInteger(reference.start, `${at}.start`),
          length: positiveInteger(reference.length, `${at}.length`),
        }
      }),
    },
    earnVaultImplementation: bytes32('earnVaultImplementation'),
    earnFeesImplementation: bytes32('earnFeesImplementation'),
    ...Object.fromEntries(
      engineFactoryHashKeys.flatMap((key) =>
        hashes[key] === undefined ? [] : [[key, bytes32(key)]],
      ),
    ),
  }
}

/** Zeros only compiler-declared immutable slots so constructor-bound runtimes remain comparable. */
function normalizeImmutableReferences(
  bytecode: Hex,
  references: readonly ImmutableReference[],
): Hex {
  const normalized = bytecode.slice(2).split('')
  for (const { start, length } of references) {
    normalized.fill('0', start * 2, (start + length) * 2)
  }
  return `0x${normalized.join('')}`
}

/** The keccak256 of the runtime code at `address`, which must have some. */
export async function runtimeCodeHash(
  client: Pick<PublicClient, 'getCode'>,
  address: Address,
  label: string,
  immutableReferences: readonly ImmutableReference[] = [],
) {
  const code = await client.getCode({ address })
  if (!code || code === '0x') throw new Error(`No runtime code at ${label} ${address}`)
  return keccak256(normalizeImmutableReferences(code, immutableReferences))
}

export async function readEarnFactory(
  client: Pick<PublicClient, 'readContract'>,
  factory: Address,
) {
  const contract = { address: factory, abi: earnFactoryAbi } as const
  const [tip20Factory, earnVaultImplementation, earnFeesImplementation] = await Promise.all([
    client.readContract({ ...contract, functionName: 'tip20Factory' }),
    client.readContract({ ...contract, functionName: 'earnVaultImplementation' }),
    client.readContract({ ...contract, functionName: 'earnFeesImplementation' }),
  ])
  return {
    tip20Factory: getAddress(tip20Factory),
    earnVaultImplementation: getAddress(earnVaultImplementation),
    earnFeesImplementation: getAddress(earnFeesImplementation),
  }
}

/** Rejects a reviewed release whose factory or immutable implementations differ from this checkout. */
export async function validateSharedFactoryRelease(
  client: Pick<PublicClient, 'getCode' | 'readContract'>,
  profile: EarnDeploymentProfile,
  expected: SharedFactoryRuntimeCodeHashes,
) {
  const { tip20Factory, earnVaultImplementation, earnFeesImplementation } = await readEarnFactory(
    client,
    profile.factories.earn,
  )
  if (tip20Factory !== getAddress(Addresses.tip20Factory)) {
    throw new Error(
      `Earn factory ${profile.factories.earn} uses TIP-20 factory ${tip20Factory}, expected ${Addresses.tip20Factory}`,
    )
  }
  const expectHash = async (
    address: Address,
    hash: `0x${string}`,
    label: string,
    immutableReferences?: readonly ImmutableReference[],
  ) => {
    const actual = await runtimeCodeHash(client, address, label, immutableReferences)
    if (actual.toLowerCase() !== hash.toLowerCase()) {
      throw new Error(
        `${label} ${address} runtime hash ${actual} does not match this checkout ${hash}; deploy and review a fresh shared factory release before deploying a profile`,
      )
    }
  }
  await Promise.all([
    expectHash(
      profile.factories.earn,
      expected.earnFactory.hash,
      'Earn factory',
      expected.earnFactory.immutableReferences,
    ),
    expectHash(
      earnVaultImplementation,
      expected.earnVaultImplementation,
      'EarnVault implementation',
    ),
    expectHash(earnFeesImplementation, expected.earnFeesImplementation, 'EarnFees implementation'),
    ...engineFactories.flatMap((factory) => {
      const hash = expected[factoryHashKey(factory)]
      return hash
        ? [expectHash(engineFactoryAddress(profile.factories, factory), hash, factory.contract)]
        : []
    }),
  ])
}
