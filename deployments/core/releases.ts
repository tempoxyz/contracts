import { getAddress, keccak256, zeroAddress, type Address, type Hex, type PublicClient } from 'viem'
import { Addresses } from 'viem/tempo'

import { earnFactoryAbi } from '../abis/index.js'
import { hostedEnvironment, type HostedEnvironmentId } from '../chain/tempo.js'
import {
  engineFactories,
  type EngineFactory,
  type EngineFactoryKey,
} from '../modules/earn/engines/index.js'
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
      earn: getAddress('0x508E90000De7c1Ac1842F83f24b028a585E9F106'),
      erc4626Engine: getAddress('0xF468B8cf6B225A94c7bC3D4489B11a94029dbcD9'),
    },
  },
  moderato: {
    factories: {
      earn: getAddress('0x6c33354f43B8f0e0b4106fe76590A9F24117C5A1'),
      erc4626Engine: getAddress('0x176859D2983ff25F095BF767F4F49dDd02a1Be62'),
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
 * Parses a release: `earn` and any engine factories, nothing else. It accepts any nonzero address and
 * normalizes it.
 */
export function parseFactoryRelease(value: unknown, path: string): EarnFactoryRelease {
  const release = object(value, path)
  exactKeys(release, path, ['earn'], engineFactoryKeys)
  return {
    earn: address(release.earn, `${path}.earn`),
    ...Object.fromEntries(
      engineFactoryKeys.flatMap((key) =>
        release[key] === undefined ? [] : [[key, address(release[key], `${path}.${key}`)]],
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
export type CompiledRuntimeCode = {
  bytecode: Hex
  references: ImmutableReference[]
  /** Every occurrence of one immutable declaration, as grouped by the compiler. */
  referenceGroups: ImmutableReference[][]
}

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
  const earnFactory = compile('src/earn/core/EarnFactory.sol:EarnFactory')
  const hash = (contract: string) => keccak256(compile(contract).bytecode)
  return {
    earnFactory: {
      hash: keccak256(normalizeImmutableReferences(earnFactory.bytecode, earnFactory.references)),
      immutableReferences: earnFactory.references,
    },
    earnVaultImplementation: hash('src/earn/core/EarnVault.sol:EarnVault'),
    earnFeesImplementation: hash('src/earn/core/EarnFees.sol:EarnFees'),
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
export function normalizeImmutableReferences(
  bytecode: Hex,
  references: readonly ImmutableReference[],
): Hex {
  const normalized = bytecode.slice(2).split('')
  for (const { start, length } of references) {
    normalized.fill('0', start * 2, (start + length) * 2)
  }
  return `0x${normalized.join('')}`
}

/**
 * Removes the compiler's CBOR metadata, whose hashes cover the source text, so builds that differ
 * only in comments compare equal: the trailing tail, then the tail of each child creation code a
 * factory embeds just before it. Code without a well-formed trailing tail is returned unchanged.
 */
export function stripMetadata(bytecode: Hex): Hex {
  const tail = metadataStart(bytecode.slice(2), false)
  if (tail === undefined) return bytecode
  let code = bytecode.slice(2, 2 + tail * 2).toLowerCase()
  // Embedded child metadata sits directly before (solc) or behind one INVALID byte (solar), and a
  // child's own children before it. Only CBOR sections and lengths go: the INVALID bytes still compare.
  let delimiters = ''
  for (;;) {
    const adjacent = metadataStart(code, true)
    if (adjacent !== undefined) {
      code = code.slice(0, adjacent * 2)
      continue
    }
    const delimited = code.endsWith('fe') ? metadataStart(code.slice(0, -2), true) : undefined
    if (delimited === undefined) break
    code = code.slice(0, delimited * 2)
    delimiters += 'fe'
  }
  return `0x${code}${delimiters}`
}

/**
 * The byte offset where the CBOR metadata ending `code` starts, or undefined. An embedded
 * section must also carry a source hash (an `ipfs`, `bzzr0`, or `bzzr1` byte string).
 */
function metadataStart(code: string, embedded: boolean) {
  if (code.length < 4) return undefined
  // The last two bytes give the CBOR length.
  const start = code.length / 2 - 2 - Number.parseInt(code.slice(-4), 16)
  if (start < 0) return undefined
  const keys = metadataMapKeys(code.slice(start * 2, -4))
  if (!keys) return undefined
  if (embedded && !['ipfs', 'bzzr0', 'bzzr1'].some((key) => keys.get(key) === 'bytes'))
    return undefined
  return start
}

/**
 * The keys of a non-empty CBOR map of text keys to byte strings, text strings, or booleans, filling
 * `hex` exactly, with each value's kind; undefined for anything else.
 */
function metadataMapKeys(hex: string) {
  const size = hex.length / 2
  let at = 0
  // One item head: its major type and argument (up to two bytes), or undefined past the end.
  const head = () => {
    if (at >= size) return undefined
    const first = Number.parseInt(hex.slice(at * 2, at * 2 + 2), 16)
    at += 1
    const info = first & 31
    const extra = info < 24 ? 0 : info === 24 ? 1 : info === 25 ? 2 : -1
    if (extra < 0 || at + extra > size) return undefined
    const argument = extra === 0 ? info : Number.parseInt(hex.slice(at * 2, (at + extra) * 2), 16)
    at += extra
    return { major: first >> 5, argument }
  }
  const map = head()
  if (map?.major !== 5 || map.argument === 0) return undefined
  const keys = new Map<string, 'bytes' | 'text' | 'boolean'>()
  for (let entry = 0; entry < map.argument; entry++) {
    const key = head()
    if (key?.major !== 3) return undefined
    const name = Buffer.from(hex.slice(at * 2, (at + key.argument) * 2), 'hex').toString('latin1')
    at += key.argument
    const value = head()
    if (!value) return undefined
    if (value.major === 2 || value.major === 3) {
      at += value.argument
      keys.set(name, value.major === 2 ? 'bytes' : 'text')
    }
    // false and true
    else if (value.major === 7 && (value.argument === 20 || value.argument === 21))
      keys.set(name, 'boolean')
    else return undefined
  }
  return at === size ? keys : undefined
}

/** Runtime code identity: its keccak256 with immutable slots zeroed and its metadata removed. */
export function runtimeCodeIdentity(bytecode: Hex, references: readonly ImmutableReference[]) {
  return keccak256(stripMetadata(normalizeImmutableReferences(bytecode, references)))
}

/** Rejects inconsistent copies of one constructor value before those bytes are normalized away. */
export function assertConsistentImmutableReferences(
  bytecode: Hex,
  groups: readonly (readonly ImmutableReference[])[],
) {
  for (const references of groups) {
    const values = references.map(({ start, length }) => {
      if (
        !Number.isSafeInteger(start) ||
        !Number.isSafeInteger(length) ||
        start < 0 ||
        length < 1 ||
        start + length > (bytecode.length - 2) / 2
      )
        throw new Error('Compiler immutable reference is outside the runtime bytecode')
      // Solar can use PUSH20 for addresses; compare values without assuming a 32-byte encoding.
      return BigInt(`0x${bytecode.slice(2 + start * 2, 2 + (start + length) * 2)}`)
    })
    if (values.some((value) => value !== values[0]))
      throw new Error('Existing engine runtime has inconsistent immutable values')
  }
}

/** The keccak256 of the runtime code at `address`, which must have some. */
export async function runtimeCodeHash(
  client: Pick<PublicClient, 'getCode'>,
  address: Address,
  label: string,
  immutableReferences: readonly ImmutableReference[] = [],
  immutableReferenceGroups: readonly (readonly ImmutableReference[])[] = [],
) {
  const code = await client.getCode({ address })
  if (!code || code === '0x') throw new Error(`No runtime code at ${label} ${address}`)
  assertConsistentImmutableReferences(code, immutableReferenceGroups)
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

/** Deployment identity supplied by an independently reviewed registry or trusted operator config. */
export type ReviewedDeploymentIdentity = {
  deployer: Address
  factories: EarnFactoryRelease
}

// These historical identities were reviewed before current release promotion; records cannot enroll themselves.
const reviewedDeploymentIdentities: Readonly<Record<string, ReviewedDeploymentIdentity>> = {
  '42431:veda-moderato': {
    deployer: getAddress('0x20b0Adf5bec8Cd881CC1795A04C1F33888769132'),
    factories: {
      earn: getAddress('0x749a947811764a14CD17fE3C7BcC5c470e2Ac5cC'),
      erc4626Engine: getAddress('0x0d57c10249eb3a92b7d81bBA6221F80F2865448A'),
    },
  },
  '42431:e2e-moderato': {
    deployer: getAddress('0x20b0Adf5bec8Cd881CC1795A04C1F33888769132'),
    factories: {
      earn: getAddress('0x749a947811764a14CD17fE3C7BcC5c470e2Ac5cC'),
      erc4626Engine: getAddress('0x0d57c10249eb3a92b7d81bBA6221F80F2865448A'),
    },
  },
  '42431:e2e-moderato-v2': {
    deployer: getAddress('0x20b0Adf5bec8Cd881CC1795A04C1F33888769132'),
    factories: {
      earn: getAddress('0x6c33354f43B8f0e0b4106fe76590A9F24117C5A1'),
      erc4626Engine: getAddress('0x176859D2983ff25F095BF767F4F49dDd02a1Be62'),
    },
  },
}

/** Rejects a hosted record whose identity has no independent reviewed baseline. Local chains remain disposable. */
export function assertReviewedDeploymentIdentity(
  record: ReviewedDeploymentIdentity & { chainId: number; deploymentId: string },
  trusted?: ReviewedDeploymentIdentity,
) {
  if (!hostedEnvironment(record.chainId)) return
  // Explicit trust enrolls unknown identities; it cannot override a registered historical baseline.
  const expected =
    reviewedDeploymentIdentities[`${record.chainId}:${record.deploymentId}`] ?? trusted
  if (!expected)
    throw new Error(
      `Deployment ${record.deploymentId} needs an independently reviewed deployer and historical factory identity; a deployment record cannot approve itself`,
    )
  if (
    getAddress(record.deployer) !== getAddress(expected.deployer) ||
    !sameFactoryRelease(
      parseFactoryRelease(record.factories, 'record.factories'),
      parseFactoryRelease(expected.factories, 'trusted.factories'),
    )
  )
    throw new Error(
      `Deployment ${record.deploymentId} does not match its independently reviewed identity`,
    )
}
