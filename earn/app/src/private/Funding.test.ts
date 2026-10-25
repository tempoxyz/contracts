import { zonePortalAbi } from '@tempoxyz/earn/abis'
import {
  ContractFunctionExecutionError,
  ContractFunctionRevertedError,
  encodeErrorResult,
  getAddress,
  isAddressEqual,
} from 'viem'
import { expect, test, vi } from 'vitest'

import { privateRouteAsset, zoneFundingTokens } from '../../deployments/tokens.js'
import { hostedPrivateStack } from '../test/HostedCatalog.js'
import { assertDepositorAdmitted } from './Admission.js'

test('the Zone can be funded with the private asset and with PATHUSD for private fees', () => {
  const { deployment, environment } = hostedPrivateStack()
  const pathUsd = environment.network.pathUsd
  const tokens = zoneFundingTokens(deployment, pathUsd)

  expect(tokens[0]).toBe(privateRouteAsset(deployment))
  expect(tokens.some((token) => isAddressEqual(token, pathUsd))).toBe(true)
  // A fee token outside the deployment's balance tokens has no known balances, so it is not offered.
  expect(zoneFundingTokens(deployment, '0x00000000000000000000000000000000000000fe')).toEqual([
    privateRouteAsset(deployment),
  ])
})

test('Deposit to Zone is refused only when the Portal rejects this depositor', async () => {
  const account = getAddress('0x0000000000000000000000000000000000000009')
  const portal = getAddress('0x5ad0000000000000000000000000000000000001')
  const options = { account, portal, token: account, zoneLabel: 'Test Zone' }
  const rejecting = (rejected: typeof account) => ({
    simulateContract: vi.fn(async () => {
      const data = encodeErrorResult({
        abi: zonePortalAbi,
        errorName: 'AccountNotAllowed',
        args: [rejected],
      })
      throw new ContractFunctionExecutionError(
        new ContractFunctionRevertedError({
          abi: zonePortalAbi,
          data,
          functionName: 'depositEncrypted',
        }),
        { abi: zonePortalAbi, args: [], contractAddress: portal, functionName: 'depositEncrypted' },
      )
    }),
  })

  await expect(assertDepositorAdmitted(rejecting(account) as never, options)).rejects.toThrow(
    `${account} is not admitted`,
  )
  // An admitted depositor's empty-payload simulation fails later, which is not a refusal.
  const other = getAddress('0x000000000000000000000000000000000000000a')
  await expect(assertDepositorAdmitted(rejecting(other) as never, options)).resolves.toBeUndefined()
})
