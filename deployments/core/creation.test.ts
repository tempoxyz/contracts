import * as ChildProcess from 'node:child_process'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, test, vi } from 'vitest'
import { encodeAbiParameters, type Hex } from 'viem'

import { deploymentStep } from '../modules/index.js'
import { parseEarnDeploymentProfile } from './profile.js'
import { assertStepCreation } from './creation.js'

vi.mock(import('node:child_process'), async (original) => ({ ...(await original()) }))

const address = `0x${'ab'.repeat(20)}` as const
const deployer = `0x${'cd'.repeat(20)}` as const
const transaction = `0x${'12'.repeat(32)}` as const
const creationBytecode = '0x6001600055' as const
const constructorArgs = encodeAbiParameters([{ type: 'address' }], [deployer])
const profile = parseEarnDeploymentProfile(
  {
    version: 1,
    id: 'creation-test',
    chainId: 4217,
    owner: deployer,
    engine: { kind: 'veda', address },
  },
  { deployer, factories: { earn: address, erc4626Engine: address } },
)

describe('assertStepCreation', () => {
  test('compiles the declared project and contract with deploy settings and no signer or compiler override', async () => {
    const fixture = setup()
    try {
      const compile = vi
        .spyOn(ChildProcess, 'execFileSync')
        .mockReturnValue(`${creationBytecode}\n`)
      await expect(assertStepCreation(fixture.options)).resolves.toBeUndefined()
      expect(compile).toHaveBeenCalledExactlyOnceWith(
        'forge',
        ['inspect', fixture.options.step.source!.contract, 'bytecode'],
        {
          cwd: join(fixture.root, 'zone-router'),
          encoding: 'utf8',
          env: { PATH: '/bin', FOUNDRY_PROFILE: 'deploy' },
        },
      )
      expect(fixture.client.getTransaction).toHaveBeenCalledExactlyOnceWith({ hash: transaction })
    } finally {
      fixture.cleanup()
    }
  })

  test('rejects malformed compiler output and implicit dotenv overrides', async () => {
    const fixture = setup()
    try {
      const compile = vi.spyOn(ChildProcess, 'execFileSync').mockReturnValue('0x__$library$__')
      await expect(assertStepCreation(fixture.options)).rejects.toThrow('invalid creation bytecode')
      expect(fixture.client.getTransaction).not.toHaveBeenCalled()
      compile.mockClear()
      writeFileSync(join(fixture.root, 'zone-router', '.env'), 'FOUNDRY_PROFILE=audit')
      await expect(assertStepCreation(fixture.options)).rejects.toThrow(
        'before running deployment tooling',
      )
      expect(compile).not.toHaveBeenCalled()
    } finally {
      fixture.cleanup()
    }
  })

  test('fails closed without exposing RPC credentials and retries with canonical input', async () => {
    const fixture = setup()
    try {
      const dependencies = { creationBytecode: () => creationBytecode }
      fixture.client.getTransaction.mockRejectedValueOnce(new Error('https://user:secret@rpc.test'))
      await expect(assertStepCreation(fixture.options, dependencies)).rejects.toThrow(
        `Cannot validate creation transaction for ${transaction}; retry when the RPC transaction is available`,
      )
      await expect(assertStepCreation(fixture.options, dependencies)).resolves.toBeUndefined()
    } finally {
      fixture.cleanup()
    }
  })

  test('leaves local batched deployments outside hosted compiler and transaction checks', async () => {
    const fixture = setup()
    try {
      const creationBytecode = vi.fn((): Hex => {
        throw new Error('Unexpected compile')
      })
      await expect(
        assertStepCreation(
          {
            ...fixture.options,
            profile: { ...profile, chainId: 1337 },
            transactions: [transaction, transaction],
          },
          { creationBytecode },
        ),
      ).resolves.toBeUndefined()
      expect(creationBytecode).not.toHaveBeenCalled()
      expect(fixture.client.getTransaction).not.toHaveBeenCalled()
      expect(fixture.client.getTransactionReceipt).not.toHaveBeenCalled()
    } finally {
      fixture.cleanup()
    }
  })
})

function setup() {
  const root = mkdtempSync(join(tmpdir(), 'creation-compiler-'))
  mkdirSync(join(root, 'earn'))
  mkdirSync(join(root, 'zone-router'))
  const step = deploymentStep('deploy-zone-router-factory')
  if (step.execution !== 'foundry' || !step.source) throw new Error('Expected direct source')
  const client = {
    getTransactionReceipt: vi.fn(async () => ({
      transactionHash: transaction,
      status: 'success',
      contractAddress: address,
      logs: [],
    })),
    getTransaction: vi.fn(async () => ({
      hash: transaction,
      from: deployer,
      to: null,
      input: `${creationBytecode}${constructorArgs.slice(2)}`,
    })),
  }
  return {
    root,
    client,
    options: {
      client: client as never,
      root: join(root, 'earn'),
      environment: {
        PATH: '/bin',
        FOUNDRY_PROFILE: 'audit',
        FOUNDRY_SOLC: '/untrusted',
        DEPLOYER_PRIVATE_KEY: 'not-forwarded',
      },
      outputs: { zoneRouterFactory: address },
      profile,
      step: { ...step, source: { ...step.source, constructorArgs: () => constructorArgs } },
      transactions: [transaction],
    },
    cleanup() {
      vi.restoreAllMocks()
      rmSync(root, { recursive: true, force: true })
    },
  }
}
