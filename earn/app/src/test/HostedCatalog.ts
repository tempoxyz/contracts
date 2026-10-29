import { parsePublicEnvironmentCatalog } from '../../deployments/catalog.js'
import generated from '../../deployments/generated.json'

/** The committed hosted catalog, parsed as the Worker parses it. */
export const hosted = parsePublicEnvironmentCatalog(generated)

/**
 * The hosted catalog's private Earn stack with its environment and Zone. Throws when no hosted
 * environment lists an available private mode, so every test that uses it fails if the app's
 * private path goes dark.
 */
export function hostedPrivateStack() {
  for (const environment of hosted.environments) {
    const zone = environment.network.zone
    const deployment = environment.stacks.find(
      (stack) => stack.modes.private?.availability === 'available',
    )
    const earnRouter = deployment?.contracts.earnRouter
    if (zone && deployment && earnRouter) return { deployment, earnRouter, environment, zone }
  }
  throw new Error('The hosted app catalog lists no private stack.')
}
