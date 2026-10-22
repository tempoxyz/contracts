import { unique } from '../core/parse.js'
import type { ProfileSlice } from './module.js'
import { accessPolicyProfile } from './access-policy/profile.js'
import { rewardsProfile } from './rewards/profile.js'
import { zoneRouterProfile } from './zone-router/profile.js'

/**
 * Every capability's browser-safe slice, in authored, record, and published-stack order. Core
 * derives the profile envelope, intent components, recorded addresses, record target, advertised
 * capabilities, and published stack fields from this list alone.
 */
export const profileSlices = [accessPolicyProfile, zoneRouterProfile, rewardsProfile] as const

/** The registry as core iterates it: every slice over the whole profile. */
export const slices = profileSlices as unknown as readonly ProfileSlice<SliceProfileFields>[]

// Each declaration has exactly one owning slice; core merges them by key, so a repeat would shadow.
for (const [label, declared] of Object.entries({
  'authored key': (slice) => slice.authoredKeys,
  'intent component': (slice) => Object.keys(slice.components ?? {}),
  'recorded address': (slice) =>
    [slice.externalAddresses, slice.addresses, slice.periphery].flatMap((map) =>
      Object.keys(map ?? {}),
    ),
  'target key': (slice) => (slice.target ? [slice.target.key] : []),
  capability: (slice) => Object.keys(slice.capabilities ?? {}),
  'stack network field': (slice) => Object.keys(slice.stack?.network ?? {}),
  'stack contract field': (slice) => Object.keys(slice.stack?.contracts ?? {}),
  'stack mode': (slice) => Object.keys(slice.stack?.modes ?? {}),
} satisfies Record<string, (slice: (typeof slices)[number]) => readonly string[]>))
  unique(slices.flatMap(declared), label)

type Slice = (typeof profileSlices)[number]

type UnionToIntersection<Union> = (Union extends unknown ? (value: Union) => void : never) extends (
  value: infer Intersection,
) => void
  ? Intersection
  : never

/** The keys of one record each slice may declare. */
type DeclaredKeys<S, Field extends string> = S extends unknown
  ? Field extends keyof S
    ? keyof S[Field] & string
    : never
  : never

/** The profile fields every slice parses. */
export type SliceProfileFields = UnionToIntersection<ReturnType<Slice['parse']>>

/** The authored JSON keys every slice may write, each omitted when unconfigured. */
export type SliceAuthoredFields = {
  [K in AuthoredKey<Authored>]?: Exclude<AuthoredValue<Authored, K>, undefined>
}

type Authored = ReturnType<Slice['authored']>
type AuthoredKey<Union> = Union extends unknown ? keyof Union : never
type AuthoredValue<Union, Key extends PropertyKey> = Union extends {
  readonly [K in Key]?: infer Value
}
  ? Value
  : never

/** Components a profile may omit, and the only ones a committed record may reconcile in place. */
export type PeripheryComponent = DeclaredKeys<Slice, 'components'>

/** Contracts optional components deploy beside the core stack, carried as `OptionalPeriphery`. */
export type OptionalPeripheryKey = DeclaredKeys<Slice, 'periphery'>

/** Recorded addresses the slices discover, deploy into their own stack fields, or deploy as periphery. */
export type SliceAddressKey =
  | DeclaredKeys<Slice, 'externalAddresses'>
  | DeclaredKeys<Slice, 'addresses'>
  | OptionalPeripheryKey

/** The intent components the slices' recorded addresses name. */
export type SliceAddressComponent = {
  [Field in 'externalAddresses' | 'addresses' | 'periphery']: Slice extends infer S
    ? S extends { readonly [K in Field]: infer Map }
      ? Map[keyof Map]
      : never
    : never
}['externalAddresses' | 'addresses' | 'periphery']

/** Capabilities the slices advertise beyond the core actions. */
export type SliceCapabilityKey = DeclaredKeys<Slice, 'capabilities'>

/** One slice's target key with its recorded identity, or `never` when it declares no target. */
type TargetOf<S> = S extends {
  readonly target: { key: infer Key extends string; discover(...args: never[]): infer Value }
}
  ? { [K in Key]?: Exclude<Value, undefined> }
  : never

/** Each slice's key of the deployment record's target, with its recorded identity. */
export type SliceTargets = UnionToIntersection<TargetOf<Slice>>

/** One slice's optional fields of one published-stack section, with their parsed types. */
type StackFieldsOf<S, Section extends string> = S extends { readonly stack: infer Stack }
  ? Section extends keyof Stack
    ? {
        [K in keyof Stack[Section]]?:
          | (Stack[Section][K] extends (...args: never[]) => infer Parsed ? Parsed : never)
          | undefined
      }
    : never
  : never

/** One section of the published stack: each slice's optional fields with their parsed types. */
export type SliceStackFields<Section extends 'network' | 'contracts' | 'modes'> =
  UnionToIntersection<StackFieldsOf<Slice, Section>>
