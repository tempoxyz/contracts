import type { MiddlewareHandler } from 'hono'

/** Adds the browser security policy shared by API and static responses. */
export function securityHeaders(options: securityHeaders.Options = {}): MiddlewareHandler {
  const development = options.environment === 'development'
  const connectSources = [
    "'self'",
    'https://auth.privy.io',
    'https://explorer-api.walletconnect.com',
  ]
  for (const url of options.sponsorUrls ?? []) connectSources.push(new URL(url).origin)
  if (options.allowLocalhost || development) {
    connectSources.push(
      'http://localhost:*',
      'http://127.0.0.1:*',
      'ws://localhost:*',
      'ws://127.0.0.1:*',
    )
  }
  const directives = [
    "default-src 'self'",
    "base-uri 'none'",
    `connect-src ${connectSources.join(' ')}`,
    "font-src 'self'",
    "form-action 'self'",
    "frame-ancestors 'none'",
    "child-src 'self' https://auth.privy.io",
    'frame-src https://auth.privy.io https://challenges.cloudflare.com',
    "img-src 'self' data: blob:",
    "manifest-src 'self'",
    "object-src 'none'",
    `script-src 'self' https://challenges.cloudflare.com${development ? " 'unsafe-inline'" : ''}`,
    "style-src 'self' 'unsafe-inline'",
  ]
  if (!options.allowLocalhost && !development) directives.push('upgrade-insecure-requests')
  const contentSecurityPolicy = directives.join('; ')
  const headers = [
    ['Content-Security-Policy', contentSecurityPolicy],
    ['Cross-Origin-Opener-Policy', 'same-origin-allow-popups'],
    ['Cross-Origin-Resource-Policy', 'same-origin'],
    ['Permissions-Policy', 'camera=(), geolocation=(), microphone=(), payment=()'],
    ['Referrer-Policy', 'strict-origin-when-cross-origin'],
    ['Strict-Transport-Security', 'max-age=31536000; includeSubDomains'],
    ['X-Content-Type-Options', 'nosniff'],
    ['X-Frame-Options', 'DENY'],
  ] as const

  return async (context, next) => {
    await next()

    context.res = new Response(context.res.body, context.res)
    for (const [name, value] of headers) context.res.headers.set(name, value)
  }
}

export declare namespace securityHeaders {
  type Options = {
    allowLocalhost?: boolean | undefined
    environment?: string | undefined
    /** The configured fee sponsors the browser calls directly. */
    sponsorUrls?: readonly string[] | undefined
  }
}
