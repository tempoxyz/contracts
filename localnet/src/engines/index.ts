import type { EngineKind } from '@tempoxyz/earn/deployments'

import { erc4626 } from './erc4626.js'
import type { LocalEngine } from './local-engine.js'
import { propamm } from './propamm.js'
import { veda } from './veda.js'

export type { LocalEngine } from './local-engine.js'

/** Localnet behavior per engine kind; shared facts live in `engineDefinitions`. */
export const localEngines: Readonly<Record<EngineKind, LocalEngine>> = { erc4626, veda, propamm }

/** The engine kind a local or devnet run deploys unless it names one. */
export const defaultEngineKind: EngineKind = 'erc4626'
