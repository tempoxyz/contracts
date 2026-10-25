import { getAddress, isAddress, zeroAddress, type Address, type Hex } from 'viem'

/**
 * Strict parsing primitives shared by every authored and generated schema: profiles, rewards,
 * records, and the public catalog. Each rejects with `${path} ...` so errors name the exact field.
 */

export function object(value: unknown, path: string): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value))
    throw new Error(`${path} must be an object`)
  return value as Record<string, unknown>
}

export function array(value: unknown, path: string): unknown[] {
  if (!Array.isArray(value)) throw new Error(`${path} must be an array`)
  return value
}

/** Rejects unknown keys, then missing required keys. */
export function exactKeys(
  value: Record<string, unknown>,
  path: string,
  required: readonly string[],
  optional: readonly string[] = [],
) {
  for (const key of Object.keys(value))
    if (!required.includes(key) && !optional.includes(key))
      throw new Error(`${path}.${key} is not supported`)
  for (const key of required) if (!(key in value)) throw new Error(`${path}.${key} is required`)
}

export function literal<const T extends string>(
  value: unknown,
  path: string,
  values: readonly T[],
): T {
  if (typeof value !== 'string' || !values.includes(value as T))
    throw new Error(`${path} must be one of ${values.join(', ')}`)
  return value as T
}

export function nonemptyString(value: unknown, path: string): string {
  if (typeof value !== 'string' || value.length === 0)
    throw new Error(`${path} must be a nonempty string`)
  return value
}

/** A nonzero address in any case, normalized to its checksum. */
export function address(value: unknown, path: string): Address {
  if (typeof value !== 'string' || !isAddress(value) || getAddress(value) === zeroAddress)
    throw new Error(`${path} must be a nonzero address`)
  return getAddress(value)
}

/** A nonzero address published exactly in checksum form. */
export function checksummedAddress(value: unknown, path: string): Address {
  const raw = nonemptyString(value, path)
  let normalized: Address
  try {
    normalized = getAddress(raw)
  } catch {
    throw new Error(`${path} must be an address`)
  }
  if (normalized !== raw) throw new Error(`${path} must be checksummed`)
  if (normalized === zeroAddress) throw new Error(`${path} must not be the zero address`)
  return normalized
}

export function nonnegativeInteger(value: unknown, path: string): number {
  if (!Number.isSafeInteger(value) || (value as number) < 0)
    throw new Error(`${path} must be a nonnegative integer`)
  return value as number
}

export function positiveInteger(value: unknown, path: string): number {
  if (!Number.isSafeInteger(value) || (value as number) <= 0)
    throw new Error(`${path} must be a positive safe integer`)
  return value as number
}

/** An unsigned base-10 integer string without leading zeros. */
export function decimalString(value: unknown, path: string): string {
  if (typeof value !== 'string' || !/^(0|[1-9][0-9]*)$/.test(value))
    throw new Error(`${path} must be an unsigned decimal string`)
  return value
}

export function bps(value: unknown, path: string): number {
  if (!Number.isSafeInteger(value) || (value as number) < 0 || (value as number) > 10_000)
    throw new Error(`${path} must be an integer between 0 and 10000`)
  return value as number
}

export function positiveBps(value: unknown, path: string): number {
  const result = bps(value, path)
  if (result === 0) throw new Error(`${path} must be positive`)
  return result
}

/** A URL without embedded credentials. */
export function url(value: unknown, path: string): string {
  const result = nonemptyString(value, path)
  let parsed: URL
  try {
    parsed = new URL(result)
  } catch {
    throw new Error(`${path} must be a valid URL`)
  }
  if (parsed.username || parsed.password) {
    throw new Error(`${path} must not contain credentials`)
  }
  return result
}

/**
 * Parses a published stack mode's availability, requiring a reason exactly when it is unavailable;
 * a capability's mode adds its `requiredFields`.
 */
export function parseMode(value: unknown, path: string, requiredFields: readonly string[] = []) {
  const mode = object(value, path)
  exactKeys(mode, path, ['availability', ...requiredFields], ['reason'])
  const availability = literal(mode.availability, `${path}.availability`, [
    'available',
    'unverified',
    'blocked',
    'unavailable',
  ] as const)
  const reason =
    mode.reason === undefined ? undefined : nonemptyString(mode.reason, `${path}.reason`)
  if (availability === 'available' && reason !== undefined) {
    throw new Error(`${path}.reason is not allowed when availability is available`)
  }
  if (availability !== 'available' && reason === undefined) {
    throw new Error(`${path}.reason is required when availability is ${availability}`)
  }
  return { availability, reason }
}

/** Rejects a repeated value; parse addresses first so equal addresses compare equal. */
export function unique(values: readonly string[], label: string) {
  const seen = new Set<string>()
  for (const value of values) {
    if (seen.has(value)) throw new Error(`Duplicate ${label}: ${value}`)
    seen.add(value)
  }
}

/** A reusable TIP-403 policy ID: neither the always-reject (0) nor always-allow (1) builtin. */
export function tip403PolicyId(value: unknown, path: string) {
  const result = decimalString(value, path)
  if (result === '0' || result === '1' || BigInt(result) > 18_446_744_073_709_551_615n)
    throw new Error(`${path} must be a reusable uint64 TIP-403 policy ID`)
  return result
}

export function isBytes32(value: unknown): value is Hex {
  return typeof value === 'string' && /^0x[0-9a-fA-F]{64}$/.test(value)
}

/**
 * Deterministic JSON with keys sorted at every level by the `en` collation, pinned so the order
 * never follows the machine's locale. Deployment and reward hashes are taken over this exact
 * output; never change it.
 */
export function canonicalJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`
  if (value && typeof value === 'object')
    return `{${Object.entries(value as Record<string, unknown>)
      .sort(([a], [b]) => a.localeCompare(b, 'en'))
      .map(([key, entry]) => `${JSON.stringify(key)}:${canonicalJson(entry)}`)
      .join(',')}}`
  return JSON.stringify(value)
}
