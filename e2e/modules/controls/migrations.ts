import { zeroAddress, type Address } from 'viem'
import type { E2eActor } from '../../harness/context.js'

/** UserOnly disables migration before authorization; only OperatorEnabled can prove NotOperator. */
export function migrationProbes(mode: number, engine: Address) {
  const probes: {
    actor: E2eActor
    engine: Address
    errorName: 'NotOperator' | 'OperatorMigrationDisabled' | 'ZeroAddress' | 'SameEngine'
  }[] = []
  if (mode === 0) {
    for (const actor of ['user', 'operator'] as const)
      probes.push({ actor, engine, errorName: 'OperatorMigrationDisabled' })
  } else if (mode === 1) {
    probes.push(
      { actor: 'user', engine, errorName: 'NotOperator' },
      { actor: 'operator', engine: zeroAddress, errorName: 'ZeroAddress' },
      { actor: 'operator', engine, errorName: 'SameEngine' },
    )
  } else throw new Error(`Unknown engine migration mode: ${mode}`)
  return probes
}
