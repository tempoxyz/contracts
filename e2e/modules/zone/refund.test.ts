import { describe, expect, it } from 'vitest'
import { getAddress, type Address } from 'viem'

import { resolveZoneRefundRecipients } from './refund.js'

const portal: Address = '0x5Ad0000000000000000000000000000000000002'
const earnVault: Address = '0x0000000000000000000000000000000000000E01'
const user: Address = '0x0000000000000000000000000000000000000A01'
const operator: Address = '0x0000000000000000000000000000000000000A02'
const outsider: Address = '0x0000000000000000000000000000000000000A04'
const actors = [outsider]

/** `roles` maps each account to its single Portal role; unlisted accounts hold none. */
function fakeClient(options: {
  accessEnforced?: boolean
  roles?: Record<Address, number>
  pending?: Address
}) {
  const reads: string[] = []
  const roles = new Map(
    Object.entries(options.roles ?? {}).map(([account, role]) => [getAddress(account), role]),
  )
  const client = {
    readContract: async (call: { functionName: string; args?: readonly unknown[] }) => {
      reads.push(call.functionName)
      if (call.functionName === 'isAccessEnforced') return options.accessEnforced ?? true
      if (call.functionName === 'operator') return operator
      if (call.functionName === 'pendingOperator')
        return options.pending ?? '0x0000000000000000000000000000000000000000'
      if (call.functionName === 'hasRole') {
        const [account, role] = call.args as [Address, number]
        return roles.get(getAddress(account)) === role
      }
      throw new Error(`unexpected ${call.functionName}`)
    },
  }
  return { client: client as never, reads }
}

describe('Zone refund recipient', () => {
  it('never redirects another actor to the customer operator', async () => {
    const { client } = fakeClient({ roles: { [outsider]: 2, [operator]: 2 } })
    const recipients = await resolveZoneRefundRecipients(client, {
      zoneId: 2,
      portal,
      earnVault,
      user,
      actors,
    })
    expect(recipients?.get(getAddress(user))).toBe(getAddress(operator))
    expect(recipients?.get(getAddress(outsider))).toBe(getAddress(outsider))
  })
})
