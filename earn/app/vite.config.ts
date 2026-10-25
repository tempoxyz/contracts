import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { cloudflare } from '@cloudflare/vite-plugin'
import { cloudflareTest } from '@cloudflare/vitest-pool-workers'
import tailwindcss from '@tailwindcss/vite'
import react from '@vitejs/plugin-react'
import regen from 'regen-ui/vite'
import { defineConfig } from 'vitest/config'
import baseConfig from '../../vite.config.js'

const isTest = Boolean(process.env.VITEST)
const usesCloudflareTestPool = process.env.CLOUDFLARE_TEST_POOL === 'true'
if (isTest) {
  process.env.PRIVY_APP_ID ??= 'test-privy-app-id'
}
const appRoot = dirname(fileURLToPath(import.meta.url))
const deploymentFile =
  process.env.TEMPO_EARN_DEPLOYMENT_FILE ?? resolve(appRoot, 'deployments/generated.json')

export default defineConfig({
  ...baseConfig,
  build: {
    sourcemap: true,
  },
  environments: {
    // The Worker must stay one module: the preview workflow uploads only
    // `dist/tempo_earn/index.js` (`--no-bundle`), so a split chunk would be missing.
    tempo_earn: {
      build: { rollupOptions: { output: { codeSplitting: false } } },
    },
  },
  // Regen source-aliases its package, so Vite does not discover these nested
  // CommonJS dependencies. Prebundle them or the dev browser fails before React mounts.
  optimizeDeps: {
    include: [
      'regen-ui > @base-ui/react/otp-field',
      'regen-ui > @base-ui/react/select',
      'regen-ui > ox > eventemitter3',
      'regen-ui > @base-ui/react > use-sync-external-store/shim',
      'regen-ui > @base-ui/react > use-sync-external-store/shim/with-selector',
    ],
  },
  resolve: {
    alias: {
      'tempo-earn-deployment': deploymentFile,
    },
  },
  plugins: [
    isTest
      ? usesCloudflareTestPool
        ? (cloudflareTest(() => ({
            main: './worker/index.ts',
            wrangler: { configPath: './wrangler.jsonc' },
          })) as never)
        : null
      : cloudflare(),
    regen({ tailwindPlugin: false }),
    react(),
    tailwindcss(),
  ],
  test: {
    ...(usesCloudflareTestPool ? { fileParallelism: false } : {}),
    include: usesCloudflareTestPool
      ? ['worker/**/*.test.{ts,tsx}', 'src/private/PrivateAction.test.ts']
      : ['src/**/*.test.{ts,tsx}'],
    exclude: usesCloudflareTestPool ? [] : ['src/private/PrivateAction.test.ts'],
    setupFiles: ['./config/test.setup.ts'],
  },
})
