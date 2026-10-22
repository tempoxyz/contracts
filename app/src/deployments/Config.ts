import { object } from '@tempoxyz/earn/deployments'

import { parsePublicEnvironmentCatalog, type PublicEnvironment } from '../../deployments/catalog.js'

export type AppEnvironment = PublicEnvironment & {
  sponsorUrl?: string | undefined
  tempoApiZoneReads: boolean
}

export type AppConfig = {
  defaultEnvironmentId: string
  environment: string
  environments: AppEnvironment[]
  privyAppId: string
}

/** Loads and validates the public Worker environment catalog. */
export async function loadConfig(options: loadConfig.Options = {}): Promise<AppConfig> {
  const fetcher = options.fetcher ?? fetch
  const response = await fetcher('/api/config', { headers: { Accept: 'application/json' } })
  const value = (await response.json()) as unknown
  if (!response.ok) {
    const message = errorMessage(value)
    throw new Error(message ?? `Configuration request failed with status ${response.status}`)
  }
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('Configuration response must be an object')
  }
  const config = value as Record<string, unknown>
  if (typeof config.privyAppId !== 'string' || config.privyAppId.length === 0) {
    throw new Error('Configuration response is missing PRIVY_APP_ID.')
  }
  if (typeof config.environment !== 'string' || !Array.isArray(config.environments)) {
    throw new Error('Configuration response is missing public environment metadata')
  }
  // The Worker adds two runtime fields to each catalog environment; split them off before parsing.
  const runtime = config.environments.map((value: unknown, index) => {
    const { sponsorUrl, tempoApiZoneReads, ...environment } = object(
      value,
      `Configuration environments[${index}]`,
    )
    if (sponsorUrl !== undefined && typeof sponsorUrl !== 'string') {
      throw new Error(`Configuration environments[${index}] has an invalid sponsor URL`)
    }
    if (typeof tempoApiZoneReads !== 'boolean') {
      throw new Error(`Configuration environments[${index}] is missing Tempo API read availability`)
    }
    return { environment, sponsorUrl, tempoApiZoneReads }
  })
  const catalog = parsePublicEnvironmentCatalog({
    defaultEnvironmentId: config.defaultEnvironmentId,
    environments: runtime.map(({ environment }) => environment),
  })
  return {
    defaultEnvironmentId: catalog.defaultEnvironmentId,
    environment: config.environment,
    environments: catalog.environments.map((environment, index) => {
      const { sponsorUrl, tempoApiZoneReads } = runtime[index]!
      return { ...environment, sponsorUrl, tempoApiZoneReads }
    }),
    privyAppId: config.privyAppId,
  }
}

function errorMessage(value: unknown) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return undefined
  const error = (value as Record<string, unknown>).error
  if (error === null || typeof error !== 'object' || Array.isArray(error)) return undefined
  const message = (error as Record<string, unknown>).message
  return typeof message === 'string' && message.length > 0 ? message : undefined
}

export declare namespace loadConfig {
  type Options = {
    fetcher?: typeof fetch | undefined
  }
}
