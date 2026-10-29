import { BaseError, ContractFunctionRevertedError } from 'viem'

/**
 * Returns the most useful concise message for a failed Earn request: the decoded Earn revert when
 * there is one, otherwise the first provider or viem message without its request data.
 */
export function message(error: unknown): string {
  const revert =
    error instanceof BaseError
      ? error.walk((candidate) => candidate instanceof ContractFunctionRevertedError)
      : undefined
  if (revert instanceof ContractFunctionRevertedError) {
    return revert.data?.errorName
      ? contractMessage(revert.data.errorName)
      : 'The Earn transaction reverted.'
  }
  return messages(error)[0] ?? 'The request failed.'
}

function contractMessage(name: string): string {
  switch (name) {
    case 'MinimumEarnSharesNotMet':
      return 'The deposit quote changed. Refresh it before trying again.'
    case 'MinimumAssetsNotMet':
      return 'The redemption quote changed. Refresh it before trying again.'
    case 'DepositsPaused':
      return 'Deposits are temporarily paused.'
    case 'MaxManagedAssetsExceeded':
      return 'This vault is currently at its deposit capacity.'
    case 'StaleAccountantRate':
      return 'Deposits are waiting for an updated vault valuation.'
    case 'PolicyForbids':
      return 'This wallet is not eligible for this action.'
    case 'EngineCapabilityUnsupported':
      return 'This vault does not support the selected action.'
    case 'TokenCallFailed':
    case 'TokenCallFalse':
    case 'TransferFailed':
      return 'Check the token balance, approval, and wallet eligibility before trying again.'
    case 'ActiveSupplyWithoutBacking':
    case 'ExcessiveConversionLoss':
    case 'InsufficientOutput':
    case 'ResidualBacking':
    case 'UnexpectedAssetsReceived':
    case 'UnexpectedVenueSharesBurned':
      return 'The vault reported an unexpected accounting result. Do not retry this action.'
    default:
      return 'The Earn transaction reverted.'
  }
}

function messages(error: unknown, seen = new Set<object>()): string[] {
  if (!error || typeof error !== 'object' || seen.has(error)) return []
  seen.add(error)
  const value = error as {
    cause?: unknown
    details?: unknown
    message?: unknown
    shortMessage?: unknown
    status?: unknown
  }
  const shortMessage = withStatus(concise(value.shortMessage), value.status)
  const causeMessages = messages(value.cause, seen)
  const deferGenericHttpMessage =
    shortMessage === 'HTTP request failed.' && causeMessages.length > 0
  return [
    ...(deferGenericHttpMessage ? causeMessages : [shortMessage, ...causeMessages]),
    ...(deferGenericHttpMessage ? [shortMessage] : []),
    concise(value.details),
    concise(value.message),
  ].filter((candidate): candidate is string => Boolean(candidate))
}

function withStatus(message: string | undefined, status: unknown) {
  return message && typeof status === 'number' ? `${message} (status ${status})` : message
}

function concise(value: unknown) {
  if (typeof value !== 'string' || !value.trim()) return undefined
  const text = value.trim()
  const detailsIndex = text.lastIndexOf('Details:')
  if (detailsIndex >= 0) {
    const versionIndex = text.indexOf('Version:', detailsIndex)
    return text
      .slice(detailsIndex + 'Details:'.length, versionIndex < 0 ? undefined : versionIndex)
      .trim()
  }
  return text.split('\n')[0]?.trim()
}

/** Whether an error or any error in its cause chain carries `text` in a message field. */
export function nestedMessageIncludes(
  error: unknown,
  text: string,
  seen = new Set<object>(),
): boolean {
  if (!error || typeof error !== 'object' || seen.has(error)) return false
  seen.add(error)
  const value = error as {
    cause?: unknown
    details?: unknown
    message?: unknown
    shortMessage?: unknown
  }
  return (
    [value.shortMessage, value.details, value.message].some(
      (candidate) => typeof candidate === 'string' && candidate.includes(text),
    ) || nestedMessageIncludes(value.cause, text, seen)
  )
}

/** A refusal whose message is already written for the user. */
export class UserFacingError extends Error {
  readonly shortMessage: string

  constructor(message: string) {
    super(message)
    this.name = 'UserFacingError'
    this.shortMessage = message
  }
}
