import { loadConfig } from '../src/deployments/Config.js'

/**
 * Post-deploy check: loads a deployed Worker's `/api/config` with the browser's own loader, so a
 * response the app cannot render fails the deploy job. Usage: `tsx check-live-config.ts <url>`.
 */
const [deploymentUrl] = process.argv.slice(2)
if (!deploymentUrl) throw new Error('Usage: check-live-config.ts <deployment-url>')

const config = await loadConfig({
  fetcher: (input, init) => fetch(new URL(String(input), deploymentUrl), init),
})
console.log(
  `Loaded ${config.environments.length} environment(s) from ${deploymentUrl}; default ${config.defaultEnvironmentId}`,
)
