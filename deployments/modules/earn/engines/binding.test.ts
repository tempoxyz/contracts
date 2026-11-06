import { getAddress, zeroAddress } from 'viem'
import { expect, test } from 'vitest'
import { readEngineBinding } from './index.js'
const address = (n: number) => getAddress(`0x${n.toString(16).padStart(40, '0')}`)

test('reports unreadable bound vaults before treating them as recovery candidates', async () => {
  let operatorReads = 0
  const client = {
    getCode: async () => '0x',
    readContract: async ({ functionName }: { functionName: string }) => {
      if (functionName === 'operator') {
        operatorReads++
        throw new Error('not a vault')
      }
      return functionName === 'earnVault' ? address(2) : address(3)
    },
  }
  await expect(readEngineBinding(client as never, address(1))).rejects.toThrow('already bound')
  expect(operatorReads).toBe(0)
  await expect(
    readEngineBinding({ ...client, getCode: async () => '0x01' } as never, address(1)),
  ).rejects.toThrow('not a readable EarnVault')
  expect(operatorReads).toBe(1)
  await expect(
    readEngineBinding(
      {
        ...client,
        readContract: async ({ functionName }: { functionName: string }) =>
          functionName === 'earnVault' ? zeroAddress : address(3),
      } as never,
      address(1),
    ),
  ).resolves.toMatchObject({ earnVault: zeroAddress, vaultOperator: undefined })
})
