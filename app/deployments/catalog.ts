import {
  array,
  exactKeys,
  nonemptyString,
  object,
  parsePublicStackCatalog,
  type PublicEarnStack,
  type PublicStackCatalog,
  type TokenMetadata,
} from '@tempoxyz/earn/deployments'
import type { Address } from 'viem'

import { privateRouteAsset } from './tokens.js'

/**
 * One listed stack: its browser-safe view plus the metadata of its private route asset, which the
 * shared stack schema does not carry. The metadata is present exactly when the stack has one.
 */
export type CatalogStack = PublicEarnStack & { privateAssetMetadata: TokenMetadata | undefined }

/** One selectable app environment: the public stacks deployed on one network. */
export type PublicEnvironment = Omit<PublicStackCatalog, 'stacks'> & {
  id: string
  stacks: CatalogStack[]
}

type PublicEnvironmentCatalog = {
  defaultEnvironmentId: string
  environments: PublicEnvironment[]
}

/** One private Zone transaction, as the Worker's display read returns it to the browser. */
export type PrivateTransaction = {
  blockNumber: number | null
  counterparty: Address | null
  direction: 'incoming' | 'outgoing'
  functionSelector: `0x${string}`
  hash: `0x${string}`
  status: 'pending' | 'reverted' | 'success'
  timestamp: string | null
}

/** Parses the browser-safe environment catalog. */
export function parsePublicEnvironmentCatalog(value: unknown): PublicEnvironmentCatalog {
  const catalog = object(value, 'environment catalog')
  exactKeys(catalog, 'environment catalog', ['defaultEnvironmentId', 'environments'])
  const environments = array(catalog.environments, 'environment catalog.environments').map(
    (value, index) => parseEnvironment(value, `environment catalog.environments[${index}]`),
  )
  const ids = environments.map((environment) => environment.id)
  if (new Set(ids).size !== ids.length) throw new Error('Duplicate environment id')
  const defaultEnvironmentId = nonemptyString(
    catalog.defaultEnvironmentId,
    'environment catalog.defaultEnvironmentId',
  )
  if (!ids.includes(defaultEnvironmentId)) {
    throw new Error(`Unknown default environment: ${defaultEnvironmentId}`)
  }
  return { defaultEnvironmentId, environments }
}

function parseEnvironment(value: unknown, path: string): PublicEnvironment {
  const { id, stacks, ...network } = object(value, path)
  const listed = array(stacks, `${path}.stacks`).map((stack, index) => {
    const { privateAssetMetadata, ...rest } = object(stack, `${path}.stacks[${index}]`)
    return { privateAssetMetadata, stack: rest }
  })
  const parsed = parsePublicStackCatalog(
    { ...network, stacks: listed.map(({ stack }) => stack) },
    path,
  )
  return {
    id: nonemptyString(id, `${path}.id`),
    ...parsed,
    stacks: parsed.stacks.map((stack, index) => {
      const metadataPath = `${path}.stacks[${index}].privateAssetMetadata`
      const metadata = listed[index]!.privateAssetMetadata
      if (!privateRouteAsset(stack)) {
        if (metadata !== undefined) throw new Error(`${metadataPath} needs a private route asset`)
        return { ...stack, privateAssetMetadata: undefined }
      }
      return { ...stack, privateAssetMetadata: parseTokenMetadata(metadata, metadataPath) }
    }),
  }
}

function parseTokenMetadata(value: unknown, path: string): TokenMetadata {
  const metadata = object(value, path)
  exactKeys(metadata, path, ['name', 'symbol', 'decimals'])
  const { decimals } = metadata
  if (
    typeof decimals !== 'number' ||
    !Number.isInteger(decimals) ||
    decimals < 0 ||
    decimals > 255
  ) {
    throw new Error(`${path}.decimals must be an integer from 0 to 255`)
  }
  return {
    name: nonemptyString(metadata.name, `${path}.name`),
    symbol: nonemptyString(metadata.symbol, `${path}.symbol`),
    decimals,
  }
}
