import { errorSummary } from '../../harness/support/utils.js'

/** Runs every restoration independently, preserving the case failure and actionable recovery details. */
export async function withRecovery(
  action: () => Promise<void>,
  restorations: readonly { label: string; restore: () => Promise<unknown> }[],
) {
  const failures: unknown[] = []
  const recovery: string[] = []
  try {
    await action()
  } catch (error) {
    failures.push(error)
  } finally {
    for (const { label, restore } of restorations) {
      try {
        await restore()
      } catch (error) {
        failures.push(error)
        recovery.push(`${label}: ${errorSummary(error)}`)
      }
    }
  }
  if (recovery.length)
    throw new AggregateError(
      failures,
      `Case failed: ${errorSummary(failures[0])}. Manual recovery required: ${recovery.join('; ')}`,
    )
  if (failures.length) throw failures[0]
}
