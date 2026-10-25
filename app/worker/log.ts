import type { MiddlewareHandler } from 'hono'
import { requestId } from 'hono/request-id'

/** Hono environment shared by the Worker routes and their request-scoped logging. */
export type AppEnv = {
  Bindings: Env
  Variables: {
    requestId: string
  }
}

type AppContext = Parameters<MiddlewareHandler<AppEnv>>[0]

export function lifecycle(): MiddlewareHandler<AppEnv> {
  return async (context, next) => {
    const startedAt = Date.now()
    emit(context, {
      event: 'request.started',
      method: context.req.method,
      requestId: context.get('requestId'),
      route: context.req.path,
    })
    try {
      await next()
      emit(context, {
        durationMs: Date.now() - startedAt,
        event: 'request.completed',
        method: context.req.method,
        requestId: context.get('requestId'),
        route: context.req.path,
        status: context.res.status,
      })
    } catch (error) {
      emit(context, {
        durationMs: Date.now() - startedAt,
        ...errorFields(error, development(context)),
        event: 'request.failed',
        level: 'error',
        method: context.req.method,
        requestId: context.get('requestId'),
        route: context.req.path,
        status: errorStatus(error),
      })
      throw error
    }
  }
}

export const identify = requestId()

/** Wraps an upstream fetch with request, response, latency, and safe error logs. */
export function outbound(context: AppContext, upstream: string): typeof fetch {
  const fetcher = globalThis.fetch
  return async (input, init) => {
    const startedAt = Date.now()
    const url = new URL(input instanceof Request ? input.url : input)
    const method = init?.method ?? (input instanceof Request ? input.method : 'GET')
    const fields = {
      host: url.host,
      method: method.toUpperCase(),
      requestId: context.get('requestId'),
      route: url.pathname,
      upstream,
    }
    emit(context, { ...fields, event: 'outbound.request' })
    try {
      const response = await fetcher(input, init)
      const responseRequestId = upstreamRequestId(response.headers)
      emit(context, {
        ...fields,
        durationMs: Date.now() - startedAt,
        event: 'outbound.response',
        ...(!response.ok ? { level: 'error' } : {}),
        ok: response.ok,
        status: response.status,
        ...(responseRequestId ? { upstreamRequestId: responseRequestId } : {}),
      })
      return response
    } catch (error) {
      emit(context, {
        ...fields,
        durationMs: Date.now() - startedAt,
        ...errorFields(error, development(context)),
        event: 'outbound.error',
        level: 'error',
      })
      throw error
    }
  }
}

function emit(context: AppContext, value: Record<string, unknown>) {
  const record = {
    service: 'tempo-earn',
    timestamp: new Date().toISOString(),
    runtime: context.env.ENVIRONMENT,
    ...value,
  }
  const output = JSON.stringify(record, null, development(context) ? 2 : undefined)
  const logger = value.level === 'error' ? console.error : console.info
  logger(output)
}

function development(context: AppContext) {
  return context.env.ENVIRONMENT === 'development'
}

function errorFields(error: unknown, verbose: boolean) {
  const value = error && typeof error === 'object' ? (error as Record<string, unknown>) : undefined
  const code = errorCode(value)
  return {
    errorType: error instanceof Error ? error.name : 'UnknownError',
    ...(code ? { errorCode: code } : {}),
    ...(typeof value?.status === 'number' ? { upstreamStatus: value.status } : {}),
    ...(verbose && error instanceof Error
      ? {
          errorMessage: error.message,
          ...(error.stack ? { errorStack: error.stack } : {}),
          ...(error.cause instanceof Error
            ? { causeMessage: error.cause.message, causeType: error.cause.name }
            : {}),
        }
      : {}),
  }
}

function errorCode(value: Record<string, unknown> | undefined) {
  if (typeof value?.code === 'string') return value.code
  if (!value?.error || typeof value.error !== 'object') return undefined
  const nested = value.error as Record<string, unknown>
  return typeof nested.code === 'string' ? nested.code : undefined
}

function upstreamRequestId(headers: Headers) {
  return headers.get('x-request-id') ?? headers.get('cf-ray') ?? undefined
}

function errorStatus(error: unknown) {
  if (!error || typeof error !== 'object' || !('status' in error)) return 500
  return typeof error.status === 'number' ? error.status : 500
}
