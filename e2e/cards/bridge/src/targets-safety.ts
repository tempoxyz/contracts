import { mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import {
  BaseError,
  HttpRequestError,
  RpcRequestError,
  TimeoutError,
  getAddress,
  pad,
  type Address,
  type Hex,
} from 'viem'

/** Only process plumbing crosses the child boundary; script inputs are explicit. */
export function childEnvironment(inputs: Record<string, string> = {}, source = process.env) {
  const names = [
    'PATH',
    'HOME',
    'TMPDIR',
    'TEMP',
    'TMP',
    'LANG',
    'LC_ALL',
    'TERM',
    'NO_COLOR',
    'SSL_CERT_FILE',
    'SSL_CERT_DIR',
  ]
  return Object.fromEntries([
    ...names.flatMap((name) => (source[name] === undefined ? [] : [[name, source[name]!]])),
    ...Object.entries(inputs),
  ])
}

/** Each invocation owns its output, including when another Forge run fails after simulation. */
export function withReport<result>(root: string, run: (out: string) => result): result {
  const reports = resolve(root, 'reports')
  mkdirSync(reports, { recursive: true })
  const directory = mkdtempSync(resolve(reports, 'bridge-run-'))
  try {
    return run(resolve(directory, 'report.json'))
  } finally {
    rmSync(directory, { force: true, recursive: true })
  }
}

/** Publishes one complete, validated record without exposing a partially written JSON file. */
export function saveRecord(path: string, value: unknown) {
  const directory = mkdtempSync(resolve(dirname(path), '.bridge-record-'))
  try {
    const temporary = resolve(directory, 'record.json')
    writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 })
    renameSync(temporary, path)
  } finally {
    rmSync(directory, { force: true, recursive: true })
  }
}

/** Requires every echoed deployment input before adopting the output's addresses. */
export function assertReportBinding(
  report: Record<string, unknown>,
  expected: Record<string, string | number>,
) {
  for (const [name, value] of Object.entries(expected)) {
    if (String(report[name]).toLowerCase() !== String(value).toLowerCase())
      throw new Error(`Deployment report does not match ${name}; the target record was not updated`)
  }
}

/** Reads only this invocation's complete JSON object. */
export function readReport(path: string): Record<string, unknown> {
  const report: unknown = JSON.parse(readFileSync(path, 'utf8'))
  if (!report || typeof report !== 'object' || Array.isArray(report))
    throw new Error('Invalid deployment report')
  return report as Record<string, unknown>
}

type Artifact = {
  deployedBytecode: {
    object: Hex
    immutableReferences?: Record<string, readonly { start: number; length: number }[]>
    linkReferences?: Record<string, unknown>
  }
}

/** Matches reviewed code, every immutable occurrence, and the complete expected immutable values. */
export function matchesRuntime(
  code: Hex | undefined,
  artifact: Artifact,
  values: readonly Hex[] = [],
) {
  const { object, immutableReferences = {}, linkReferences = {} } = artifact.deployedBytecode
  if (
    !code ||
    code === '0x' ||
    !/^0x[0-9a-f]+$/i.test(object) ||
    code.length !== object.length ||
    Object.keys(linkReferences).length
  )
    return false
  const groups = Object.values(immutableReferences)
  if (groups.length !== values.length) return false
  let actual = code.toLowerCase()
  const expectedValues = values.map((value) => pad(value).toLowerCase()).sort()
  const actualValues: string[] = []
  const occupied = new Set<number>()
  for (const references of groups) {
    if (!references.length) return false
    let value: string | undefined
    for (const { start, length } of references) {
      if (
        !Number.isInteger(start) ||
        start < 0 ||
        length !== 32 ||
        2 * (start + length) + 2 > code.length
      )
        return false
      for (let index = start; index < start + length; index++) {
        if (occupied.has(index)) return false
        occupied.add(index)
      }
      const begin = 2 + start * 2
      const end = begin + length * 2
      const current = `0x${code.slice(begin, end)}`.toLowerCase()
      if (value !== undefined && current !== value) return false
      value = current
      actual = actual.slice(0, begin) + object.slice(begin, end).toLowerCase() + actual.slice(end)
    }
    actualValues.push(value!)
  }
  return (
    actual === object.toLowerCase() &&
    JSON.stringify(actualValues.sort()) === JSON.stringify(expectedValues)
  )
}

/** Gateway status survives viem's JSON-RPC error wrapping, not just HttpRequestError. */
export function sendFailure(error: unknown) {
  const hasTransientCode = (value: unknown) =>
    typeof value === 'object' &&
    value !== null &&
    'code' in value &&
    typeof value.code === 'number' &&
    [-1, -32005, -32603].includes(value.code)
  const cause =
    error instanceof BaseError
      ? error.walk(
          (item) =>
            item instanceof HttpRequestError ||
            item instanceof TimeoutError ||
            (item instanceof RpcRequestError && (item.status === 502 || item.status === 504)) ||
            hasTransientCode(item),
        )
      : undefined
  const transient =
    cause instanceof HttpRequestError ||
    cause instanceof TimeoutError ||
    (cause instanceof RpcRequestError && (cause.status === 502 || cause.status === 504)) ||
    hasTransientCode(cause)
  const status =
    cause instanceof HttpRequestError || cause instanceof RpcRequestError ? cause.status : undefined
  return { transient, cutShort: status === 502 || status === 504 }
}

/** Router role transitions are operator decisions; never silently revoke existing Portal roles. */
export function routerTransition(options: {
  router: Address
  portal: Address
  gatewayOpen: boolean
  accessEnforced: boolean
  accountRole: boolean
  gatewayRole: boolean
}) {
  const { router, portal, gatewayOpen, accessEnforced, accountRole, gatewayRole } = options
  const revoke =
    !gatewayOpen && accountRole
      ? 'setAllowedAccount'
      : gatewayOpen && accessEnforced && gatewayRole
        ? 'setGateway'
        : undefined
  if (!revoke) return undefined
  const grant = gatewayOpen ? 'setAllowedAccount' : 'setGateway'
  return `Router role transition requires the Zone admin: call ${revoke}(${router}, false), then ${grant}(${router}, true) on portal ${portal}; no roles were changed by this run`
}

/** A successful read proving wrong ownership differs from an unavailable Safe RPC read. */
export async function safeControl(options: {
  readOwners(): Promise<readonly Address[]>
  readThreshold(): Promise<bigint>
  account: Address
  safe: Address
}) {
  const [owners, threshold] = await Promise.all([
    options.readOwners(),
    options.readThreshold(),
  ]).catch(() => {
    throw new Error(
      `Could not read Safe authority at ${options.safe}; no ownership conclusion was reached. Retry the RPC reads before changing keys.`,
    )
  })
  if (
    threshold !== 1n ||
    owners.length !== 1 ||
    getAddress(owners[0]!) !== getAddress(options.account)
  )
    throw new Error(
      `The key ${options.account} is not the sole owner of threshold-1 Safe ${options.safe}`,
    )
}
