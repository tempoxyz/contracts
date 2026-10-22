/** How long any E2E transaction, receipt, or polled condition may take. */
export const TIMEOUT_MS = 180_000

/** A case precondition the target does not meet; the runner reports the case as blocked. */
export class E2ePrerequisiteError extends Error {
  override name = 'E2ePrerequisiteError'
}

/**
 * Polls `fn` until it returns a value, for up to three minutes unless `timeoutMs` says otherwise.
 * An error is retried unless the RPC refused the request, which no retry can fix.
 */
export async function waitFor<T>(
  label: string,
  fn: () => Promise<T | undefined>,
  options: { timeoutMs?: number; intervalMs: number },
) {
  const deadline = Date.now() + (options.timeoutMs ?? TIMEOUT_MS)
  let lastError: unknown
  while (Date.now() < deadline) {
    try {
      const result = await fn()
      if (result !== undefined) return result
    } catch (error) {
      if (refusedRequest(error)) throw error
      lastError = error
    }
    await new Promise((resolve) => setTimeout(resolve, options.intervalMs))
  }
  throw new Error(
    `Timed out waiting for ${label}${lastError ? `; last error: ${errorSummary(lastError)}` : ''}`,
  )
}

/** An HTTP 4xx other than a timeout or rate limit, anywhere in the error's cause chain. */
function refusedRequest(error: unknown): boolean {
  if (typeof error !== 'object' || error === null) return false
  const { status, cause } = error as { status?: unknown; cause?: unknown }
  if (typeof status === 'number' && status >= 400 && status < 500) {
    return status !== 408 && status !== 429
  }
  return refusedRequest(cause)
}

export function errorSummary(error: unknown) {
  if (typeof error === 'object' && error !== null) {
    const record = error as Record<string, unknown>
    const status = typeof record.status === 'number' ? `HTTP ${record.status}` : undefined
    const shortMessage = typeof record.shortMessage === 'string' ? record.shortMessage : undefined
    const metaMessages = Array.isArray(record.metaMessages)
      ? record.metaMessages.filter((message): message is string => typeof message === 'string')
      : []

    if (status !== undefined || shortMessage !== undefined) {
      const details = [status, shortMessage, ...metaMessages].filter(
        (message) => message !== undefined,
      )
      return details.join(': ')
    }
  }

  if (error instanceof Error) return error.message.split('\n')[0] ?? error.message
  return String(error)
}

/** Private-asset units each Zone case converts through the router (1 unit at six decimals). */
export const ZONE_CASE_AMOUNT = 1_000_000n

export function assert(condition: boolean, message: string): asserts condition {
  if (!condition) throw new Error(message)
}

export function assertValueNotReducedBeyondOneBasisPoint(
  after: bigint,
  before: bigint,
  message: string,
) {
  assert(after * 10_000n >= before * 9_999n, `${message}: before=${before}, after=${after}`)
}
