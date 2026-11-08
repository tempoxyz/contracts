import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  BaseError,
  ContractFunctionRevertedError,
  ContractFunctionZeroDataError,
  getAddress,
  zeroAddress,
  type Address,
} from 'viem'
import { describe, expect, test, vi } from 'vitest'

import { zoneRouterAbi } from '../../abis/index.js'
import { pendingDeploymentPath } from '../../core/bundle.js'
import { planEarnDeployment } from '../../core/plan.js'
import { restorePendingDeployment } from '../../core/pending.js'
import { componentDeploymentIntentHashes, parseEarnDeploymentProfile } from '../../core/profile.js'
import { prepareLifecycleStep } from '../../core/reconcile.js'
import type { ChainClient } from '../module.js'
import { zoneRouterModeModule } from './index.js'
import { zoneRouterMode, zoneRouterModeProfile } from './profile.js'
import { deployZoneRouter } from './steps.js'

const rpc = vi.hoisted(() => ({ client: undefined as ChainClient | undefined }))
vi.mock(import('../../chain/runtime.js'), async (original) => ({
  ...(await original()),
  rpcClient: () => rpc.client as never,
}))

const address = (suffix: string) => getAddress(`0x${suffix.padStart(40, '0')}`)
const profile = parseEarnDeploymentProfile(
  {
    version: 1,
    id: 'legacy-zone-router',
    chainId: 42431,
    engine: { kind: 'erc4626', venue: address('2') },
    zoneRouter: { zoneId: 7, ops: ['deposit', 'redeem'], earn: { privateAsset: address('a') } },
  },
  { deployer: address('3'), factories: { earn: address('4'), erc4626Engine: address('1') } },
)
const outputs = {
  asset: address('a'),
  earnShare: address('5'),
  earnVault: address('e'),
  zoneRouterFactory: address('f'),
  zoneRouter: address('9'),
  zoneRouterPortal: address('8'),
}
const refusal = `ZoneRouter ${outputs.zoneRouter} does not expose a readable spenders() list`

describe('retained Zone router ABI compatibility', () => {
  test.each([
    new ContractFunctionZeroDataError({ functionName: 'spenders' }),
    new ContractFunctionRevertedError({ abi: zoneRouterAbi, functionName: 'spenders' }),
    new BaseError('Contract read failed', {
      cause: new ContractFunctionZeroDataError({ functionName: 'spenders' }),
    }),
  ])(
    'refuses a legacy settlers-only Earn router without treating it as a redeployment',
    async (error) => {
      const client = chain(error)
      await expect(deployZoneRouter.satisfied(client, profile, outputs)).rejects.toMatchObject({
        cause: error,
        message: expect.stringContaining(refusal),
      })
      await expect(zoneRouterModeModule.inspect!(client, profile, outputs)).rejects.toThrow(refusal)
      await expect(
        zoneRouterModeModule.stackAccessPrincipals!(client, {
          contracts: { earnShare: outputs.earnShare, zoneRouter: outputs.zoneRouter },
          operations: {},
        } as never),
      ).rejects.toThrow(refusal)
      expect(client.readContract).not.toHaveBeenCalledWith(
        expect.objectContaining({ functionName: 'settlers' }),
      )
    },
  )

  test('accepts a current Earn router with a real empty spender list', async () => {
    await expect(deployZoneRouter.satisfied(chain(), profile, outputs)).resolves.toBe(true)
  })

  test('preserves transport errors rather than diagnosing a legacy contract', async () => {
    const error = new BaseError('RPC unavailable')
    await expect(deployZoneRouter.satisfied(chain(error), profile, outputs)).rejects.toBe(error)
  })

  test('retains release-1 identities and history but stops resume before preparing a transaction', async () => {
    const root = mkdtempSync(join(tmpdir(), 'zone-router-compatibility-'))
    try {
      const profilePath = join(root, 'profile.json')
      const completed = {
        completedAt: '2026-01-01T00:00:00.000Z',
        verification: 'chain' as const,
        transactions: [`0x${'a'.repeat(64)}` as const],
      }
      const committed = {
        componentDeploymentIntentHashes: componentDeploymentIntentHashes(profile),
        addresses: outputs,
        actions: { 'deploy-zone-router-factory': completed, 'deploy-zone-router': completed },
      }
      const before = structuredClone(committed)
      expect(zoneRouterModeProfile.components.zoneRouter(profile, 'deployment')).toMatchObject({
        contractRelease: 1,
      })
      expect(
        zoneRouterModeProfile.components.zoneRouterFactory(profile, 'deployment'),
      ).toMatchObject({ contractRelease: 1 })
      const restored = restorePendingDeployment(profilePath, profile, committed)
      expect(restored.outputs.zoneRouter).toBe(outputs.zoneRouter)
      expect(restored.outputs.zoneRouterFactory).toBe(outputs.zoneRouterFactory)
      expect(restored.actions).toEqual(committed.actions)
      const pending = readFileSync(pendingDeploymentPath(profilePath), 'utf8')
      rpc.client = chain(new ContractFunctionZeroDataError({ functionName: 'spenders' }))
      await expect(
        prepareLifecycleStep({
          root,
          profilePath,
          profile,
          rpcUrl: 'https://rpc.invalid',
          environment: {},
          actions: planEarnDeployment(profile).filter(
            (action) => action.id === 'deploy-zone-router',
          ),
        }),
      ).rejects.toThrow(
        'Keep the recorded addresses and source evidence unchanged; source re-verification cannot upgrade an immutable router.',
      )
      expect(readFileSync(pendingDeploymentPath(profilePath), 'utf8')).toBe(pending)
      expect(committed).toEqual(before)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})

/** The historical Earn ABI has settlers(), not spenders(), with otherwise matching bindings. */
function chain(error?: Error) {
  const mode = zoneRouterMode(profile, outputs)
  const reads: Record<string, unknown> = {
    isRouter: true,
    predict: outputs.zoneRouter,
    portal: outputs.zoneRouterPortal,
    enabledOps: mode.enabledOps,
    settlers: [],
    spenders: [],
    allowedZoneId: mode.zoneId,
    earnVault: outputs.earnVault,
    privateAsset: outputs.asset,
    vaultAsset: outputs.asset,
    earnShare: outputs.earnShare,
    pool: zeroAddress,
    customerId: mode.customerId,
    privateAssetIsBase: false,
  }
  return {
    getCode: vi.fn(async () => '0x6080' as const),
    readContract: vi.fn(async ({ functionName }: { address: Address; functionName: string }) => {
      if (functionName === 'spenders' && error) throw error
      if (!(functionName in reads)) throw new Error(`Unexpected read: ${functionName}`)
      return reads[functionName]
    }),
  } as unknown as ChainClient
}
