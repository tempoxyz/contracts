import { accessCommand } from './access-policy/cli.js'
import type { CapabilityCommand } from './module.js'

/**
 * Every capability's `pnpm earn <name>` subcommand. Node-only, so it is registered apart from
 * `modules/index.ts`, which the operations entry loads.
 */
export const capabilityCommands: readonly CapabilityCommand[] = [accessCommand]
