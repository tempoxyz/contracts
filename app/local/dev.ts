import { spawn } from 'node:child_process'
import { mkdirSync, writeFileSync } from 'node:fs'
import { dirname, relative, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { engineDefinitions, publicStack } from '@tempoxyz/earn/deployments'
import type { EarnStack } from '@tempoxyz/earn/deployments/operations'
import { Environment, localStack } from 'localnet'
import { createPublicClient, http } from 'viem'

import { parsePublicEnvironmentCatalog } from '../deployments/catalog.js'
import { privateRouteAsset, readMetadata } from '../deployments/tokens.js'

const appRoot = dirname(dirname(fileURLToPath(import.meta.url)))
const root = dirname(appRoot)
const localDirectory = resolve(appRoot, '.local')
const catalogPath = resolve(localDirectory, 'catalog.json')

mkdirSync(localDirectory, { recursive: true })

async function runLocalApp(options: runLocalApp.Options = {}) {
  await Environment.run({
    access: 'open',
    consumer: options.smoke ? 'app setup smoke test' : 'app development',
    ready: async (environment) => {
      const catalog = parsePublicEnvironmentCatalog(await localCatalog(environment))
      writeFileSync(catalogPath, `${JSON.stringify(catalog, null, 2)}\n`)
      console.log(`\nLocal app catalog · ${relative(root, catalogPath)}`)
      const { alternateAsset, stablecoinFixture } = environment.deployment
      console.log(
        `Private asset ${alternateAsset} · fund(token, recipient, amount) on ${stablecoinFixture}\n`,
      )
      if (!options.smoke) {
        console.log('Starting Earn app at http://localhost:5173 …')
        await runApp(catalogPath)
      }
    },
  })
}

declare namespace runLocalApp {
  type Options = {
    smoke?: boolean | undefined
  }
}

/** Builds the browser-safe catalog of the one disposable local app environment. */
async function localCatalog(environment: Environment.State) {
  // The Worker proxies the Zone's unauthenticated node RPC as hosted Worker reads use the Tempo API
  // key; the private RPC needs per-account tokens and neither local RPC answers CORS.
  const stack = localStack(environment, { publicZoneRpc: true })
  const { tip20Factory: _tip20Factory, ...network } = stack.network
  const description = `Disposable ${engineDefinitions[stack.engineKind].label} stack running on an isolated Tempo and Zone.`
  // The browser view allowlists fields; it never reads the provenance metadata a local stack lacks.
  const listed = publicStack(stack as EarnStack, description)
  const privateAsset = privateRouteAsset(listed)
  const client = createPublicClient({ transport: http(environment.l1.rpcUrl) })
  return {
    defaultEnvironmentId: 'local',
    environments: [
      {
        id: 'local',
        network,
        defaultStackId: stack.id,
        stacks: [
          {
            ...listed,
            privateAssetMetadata: privateAsset
              ? await readMetadata(client, privateAsset)
              : undefined,
          },
        ],
      },
    ],
  }
}

await runLocalApp({ smoke: process.argv.includes('--smoke') })

async function runApp(deploymentFile: string) {
  let stopping = false
  const child = spawn('pnpm', ['--filter', 'app', 'dev'], {
    cwd: root,
    env: { ...process.env, TEMPO_EARN_DEPLOYMENT_FILE: deploymentFile },
    stdio: 'inherit',
  })
  const onInterrupt = () => {
    stopping = true
    child.kill('SIGINT')
  }
  const onTerminate = () => {
    stopping = true
    child.kill('SIGTERM')
  }
  process.once('SIGINT', onInterrupt)
  process.once('SIGTERM', onTerminate)
  try {
    await new Promise<void>((resolvePromise, reject) => {
      child.once('error', reject)
      child.once('exit', (code, signal) => {
        if (!stopping && code && signal === null)
          reject(new Error(`Earn app exited with code ${code}`))
        else resolvePromise()
      })
    })
  } finally {
    process.off('SIGINT', onInterrupt)
    process.off('SIGTERM', onTerminate)
  }
}
