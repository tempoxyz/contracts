import { cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { createServer } from 'node:http'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, test } from 'vitest'
import { loadEarnProfile, loadEarnProfileBundle } from './bundle.js'
import { loadHostedProfileStack } from './profile-stack.js'
import {
  componentDeploymentIntentHashes,
  deploymentIntentHash,
  profileFactoryDeploymentId,
} from './profile.js'

const repository = fileURLToPath(new URL('../..', import.meta.url))

describe('loadHostedProfileStack', () => {
  test.each(['argument', 'file'] as const)(
    'loads independent identity from %s before enforcing the live chain fence',
    async (source) => {
      const fixture = externalProfile()
      const rpc = await wrongChainRpc(fixture.record.target.genesisHash)
      try {
        const identityPath = join(fixture.root, 'reviewed-identity.json')
        writeFileSync(identityPath, JSON.stringify(fixture.trusted))
        await expect(
          loadHostedProfileStack(
            fixture.path,
            {
              TEMPO_RPC_URL: rpc.url,
              EARN_TRUSTED_DEPLOYMENT_IDENTITY:
                source === 'file' ? identityPath : join(fixture.root, 'unused-identity.json'),
            },
            source === 'argument' ? fixture.trusted : undefined,
          ),
        ).rejects.toThrow('RPC chain ID does not match')
        expect(rpc.methods.sort()).toEqual(['eth_chainId', 'eth_getBlockByNumber'])
      } finally {
        await rpc.close()
        rmSync(fixture.root, { recursive: true, force: true })
      }
    },
  )

  test('does not trust an unknown profile record or accept that record as an identity file', async () => {
    const fixture = externalProfile()
    const rpc = await wrongChainRpc(fixture.record.target.genesisHash)
    try {
      await expect(
        loadHostedProfileStack(fixture.path, { TEMPO_RPC_URL: rpc.url }),
      ).rejects.toThrow('cannot approve itself')
      await expect(
        loadHostedProfileStack(fixture.path, {
          TEMPO_RPC_URL: rpc.url,
          EARN_TRUSTED_DEPLOYMENT_IDENTITY: fixture.recordPath,
        }),
      ).rejects.toThrow('not a deployment record')
      expect(rpc.methods).toEqual([])
    } finally {
      await rpc.close()
      rmSync(fixture.root, { recursive: true, force: true })
    }
  })
})

function externalProfile() {
  const root = mkdtempSync(join(tmpdir(), 'earn-hosted-profile-'))
  const directory = join(root, 'profiles', 'external')
  const knownPath = join(repository, 'profiles', 'veda-moderato', 'profile.json')
  cpSync(join(repository, 'profiles', 'veda-moderato'), directory, { recursive: true })
  const path = join(directory, 'profile.json')
  const authored = JSON.parse(readFileSync(path, 'utf8'))
  authored.id = 'external'
  writeFileSync(path, JSON.stringify(authored))
  const known = loadEarnProfileBundle(knownPath)
  const trusted = { deployer: known.profile.deployer, factories: known.profile.factories }
  const profile = loadEarnProfile(path, trusted)
  const record = {
    ...known.record,
    deploymentId: profile.id,
    deploymentIntentHash: deploymentIntentHash(profile),
    componentDeploymentIntentHashes: componentDeploymentIntentHashes(profile),
    source: {
      ...known.record.source,
      factoryDeploymentId: profileFactoryDeploymentId(profile),
    },
  }
  const recordPath = join(directory, 'deployment.json')
  writeFileSync(recordPath, JSON.stringify(record))
  return { root, path, recordPath, trusted, record }
}

async function wrongChainRpc(genesisHash: string) {
  const methods: string[] = []
  const server = createServer(async (request, response) => {
    let body = ''
    for await (const chunk of request) body += chunk.toString()
    const { id, method } = JSON.parse(body)
    methods.push(method)
    response.setHeader('Content-Type', 'application/json')
    response.end(
      JSON.stringify({
        jsonrpc: '2.0',
        id,
        result:
          method === 'eth_chainId'
            ? '0x1'
            : { hash: genesisHash, number: '0x0', timestamp: '0x0', transactions: [] },
      }),
    )
  })
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  const address = server.address()
  if (!address || typeof address === 'string') throw new Error('Test RPC has no listening port')
  return {
    methods,
    url: `http://127.0.0.1:${address.port}`,
    close: () =>
      new Promise<void>((resolve, reject) =>
        server.close((error) => (error ? reject(error) : resolve())),
      ),
  }
}
