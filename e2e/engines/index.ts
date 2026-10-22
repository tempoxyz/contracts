import { readdirSync } from 'node:fs'

import { engineKinds, type EngineKind } from '@tempoxyz/earn/deployments'
import type { Address } from 'viem'
import type { E2eContext } from '../harness/context.js'

/**
 * E2E behavior that differs by engine kind. Shared facts and reads such as labels, capabilities,
 * and deposit quotes live in `engineDefinitions`; this holds only what the harness itself does
 * differently per engine.
 */
export type E2eEngine = {
  /** Exact assets an immediate redemption of `earnShares` pays at the current state. */
  quoteRedeem(context: E2eContext, earnShares: bigint): Promise<bigint>
  /**
   * The Morpho fee wrapper over this engine's ERC-4626 venue that the wrapper-migration cases
   * replace, or undefined when the stack has none. Absent when the venue cannot be wrapped.
   */
  morphoFeeWrapper?(context: E2eContext): Address | undefined
}

/** Optional engine behavior a case can require. */
export type E2eEngineHook = 'morphoFeeWrapper'

const enginesDirectory = new URL('./', import.meta.url)
const discovered = readdirSync(enginesDirectory, { withFileTypes: true })
  .filter((entry) => entry.isDirectory())
  .map((entry) => entry.name)
  .sort()
// Every engine kind needs its E2E behavior, and every folder must name an engine kind.
if (discovered.join() !== [...engineKinds].sort().join()) {
  throw new Error(`E2E engines ${discovered.join(', ')} do not match ${engineKinds.join(', ')}`)
}

/**
 * Per-engine E2E behavior, keyed like `engineDefinitions` and discovered from
 * `engines/<kind>/engine.ts`, so adding an engine's E2E behavior is adding its folder.
 */
export const e2eEngines = Object.fromEntries(
  await Promise.all(
    discovered.map(async (kind) => {
      const { engine } = (await import(new URL(`${kind}/engine.ts`, enginesDirectory).href)) as {
        engine: E2eEngine
      }
      return [kind, engine] as const
    }),
  ),
) as Readonly<Record<EngineKind, E2eEngine>>
