import { Hono } from 'hono'

import { createConfig, isLocalDeployment, rpcUpstream, sponsorUrls } from './config.js'
import * as Log from './log.js'
import * as RpcProxy from './rpc-proxy.js'
import { securityHeaders } from './security-headers.js'
import * as ZoneReads from './zone-reads.js'

export const app = new Hono<Log.AppEnv>()

app.use('*', Log.identify)
app.use('*', Log.lifecycle())
app.use('*', (context, next) =>
  securityHeaders({
    allowLocalhost: isLocalDeployment,
    environment: context.env.ENVIRONMENT,
    sponsorUrls,
  })(context, next),
)

app.get('/health', (context) => context.json({ status: 'ok' }))

app.get('/api/config', (context) => {
  if (!context.env.PRIVY_APP_ID) {
    return context.json(
      {
        error: {
          code: 'missing_environment',
          message: 'Server configuration is missing required Privy settings: PRIVY_APP_ID.',
          requestId: context.get('requestId'),
        },
      },
      503,
    )
  }
  return context.json(createConfig(context.env, new URL(context.req.url).origin))
})

app.post('/api/environments/:environmentId/:route{l1-rpc|zone-rpc}', async (context) => {
  const route = context.req.param('route')
  const kind = route === 'l1-rpc' ? 'l1' : 'zone'
  const upstream = rpcUpstream(context.req.param('environmentId'), kind, context.env)
  if (!upstream) return context.json({ error: 'Unknown environment.' }, 404)
  return await RpcProxy.proxy(
    context.req.raw,
    upstream.url,
    { kind, upstreamHeaders: upstream.headers },
    Log.outbound(context, route),
  )
})

app.post(
  '/api/environments/:environmentId/zones/:zoneId/:read{balances|transactions}',
  async (context) => {
    const zoneId = Number(context.req.param('zoneId'))
    if (!Number.isSafeInteger(zoneId)) return context.json({ error: 'Unknown Zone.' }, 404)
    return await ZoneReads.read(context.req.raw, context.req.param('read') as ZoneReads.ZoneRead, {
      apiKey: context.env.TEMPO_API_KEY,
      environmentId: context.req.param('environmentId'),
      fetcher: Log.outbound(context, 'tempo-api'),
      zoneId,
    })
  },
)

app.get('*', (context) => context.env.ASSETS.fetch(context.req.raw))

app.onError((_error, context) =>
  context.json(
    {
      error: {
        code: 'internal_error',
        message: 'The server could not complete the request.',
        requestId: context.get('requestId'),
      },
    },
    500,
  ),
)

export default app
