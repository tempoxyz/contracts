import { createServer } from 'node:http'
import { once } from 'node:events'
import { erc20Abi, http, keccak256, numberToHex, type Address, type Hex } from 'viem'
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts'
import { Account, Actions, Store, Transaction, createClient, http as zoneHttp } from 'viem/tempo'
import { describe, expect, it } from 'vitest'
import * as FeeEvidence from './fee-evidence.js'
import * as Network from './network.js'
import { portalAbi } from './targets.js'

const other = '0x1111111111111111111111111111111111111111'
const blockHash = `0x${'aa'.repeat(32)}` as Hex
const anotherHash = `0x${'bb'.repeat(32)}` as Hex

describe('resolve', () => {
  it('decodes the pinned Zone receipt omission and RPC null sponsor marker', async () => {
    // Captured from the opt-in native approval test after an encrypted deposit into a fresh Zone.
    const payer = '0x505c64219425272eaB0c16615AF3C6a51783462e'
    const hash = '0x24ebdca81dd7c3007950687b9d54701a3f42f4bf95a9eecd531fa57a55ce3774'
    const block = '0xdf37378daa66bf18d68652abe21a68fb02cc8a09ffb00349101321a35bb1fcf2'
    const evidence = {
      payer,
      key: payer,
      receipt: {
        transactionHash: hash,
        blockHash: block,
        blockNumber: 6n,
        gasUsed: 371356n,
        effectiveGasPrice: 0n,
        feePayer: payer,
      },
      raw: '0x76f8cc8605390000000180808305baaff85ef85c9420c000000000000000000000000000000000000080b844095ea7b30000000000000000000000001c000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000001c0808080809420c000000000000000000000000000000000000080c0b841bb79cada4820d4e5b8d26aa1cccff3a3aebdfb77615e59b97041532ab709e0e4524fe23e3354466edbc01da491c50e9ad3b8fd6be79237b4abdd4748f491a6311b',
      transaction: {
        hash,
        blockHash: block,
        blockNumber: '0x6',
        from: payer,
        feeToken: Network.address.pathUsd,
        feePayerSignature: null,
      },
      block: { hash: block, number: '0x6', transactions: [hash] },
    } satisfies Evidence
    await withRpc(evidence, async (client) => {
      expect(await FeeEvidence.resolve(client, evidence.receipt, payer)).toEqual({
        feePayer: payer,
        feeToken: Network.address.pathUsd,
      })
    })
  })

  it.each([false, true])('recovers the signed root payer (access key: %s)', async (access) => {
    const evidence = await fixture({ access })
    await withRpc(evidence, async (client) => {
      expect(await FeeEvidence.resolve(client, evidence.receipt, evidence.payer)).toEqual({
        feePayer: evidence.payer,
        feeToken: Network.address.pathUsd,
      })
      expect(
        await FeeEvidence.resolve(
          client,
          { ...evidence.receipt, feePayer: evidence.payer, feeToken: Network.address.pathUsd },
          evidence.payer,
        ),
      ).toEqual({ feePayer: evidence.payer, feeToken: Network.address.pathUsd })
    })
  })

  it.each(['feePayer', 'feeToken'] as const)('rejects conflicting receipt %s', async (field) => {
    const evidence = await fixture()
    await withRpc(evidence, async (client) => {
      await expect(
        FeeEvidence.resolve(client, { ...evidence.receipt, [field]: other }, evidence.payer),
      ).rejects.toThrow('conflicting receipt')
    })
  })

  it.each([
    ['hash', anotherHash],
    ['blockHash', anotherHash],
    ['blockNumber', '0x2'],
    ['blockNumber', null],
    ['from', other],
    ['feeToken', other],
    ['feePayer', other],
    ['feePayerSignature', {}],
  ])('rejects inconsistent mined transaction %s', async (field, value) => {
    const evidence = await fixture()
    evidence.transaction[String(field)] = value
    await withRpc(evidence, async (client) => {
      await expect(FeeEvidence.resolve(client, evidence.receipt, evidence.payer)).rejects.toThrow(
        'Fee evidence',
      )
    })
  })

  it.each([
    ['hash', anotherHash],
    ['number', '0x2'],
    ['transactions', []],
  ])('rejects a changed canonical block %s', async (field, value) => {
    const evidence = await fixture()
    evidence.block[String(field)] = value
    await withRpc(evidence, async (client) => {
      await expect(FeeEvidence.resolve(client, evidence.receipt, evidence.payer)).rejects.toThrow(
        'Fee evidence',
      )
    })
  })

  it('rejects replacement signed bytes even when parsed RPC identities match', async () => {
    const evidence = await fixture()
    evidence.raw = (await fixture()).raw
    await withRpc(evidence, async (client) => {
      await expect(FeeEvidence.resolve(client, evidence.receipt, evidence.payer)).rejects.toThrow(
        'signed transaction hash',
      )
    })
  })

  it.each([null, '0x02abcd', '0x76ff'])(
    'rejects missing, legacy or malformed raw bytes: %s',
    async (raw) => {
      const evidence = await fixture()
      evidence.raw = raw
      if (raw?.startsWith('0x76')) rebindHash(evidence, keccak256(raw as Hex))
      await withRpc(evidence, async (client) => {
        await expect(
          FeeEvidence.resolve(client, evidence.receipt, evidence.payer),
        ).rejects.toThrow()
      })
    },
  )

  it.each([
    { feeToken: undefined },
    { feeToken: other },
    { feePayerSignature: null },
    { feePayerSignature: { r: anotherHash, s: anotherHash, yParity: 0 } },
  ] satisfies readonly FeeOverrides[])(
    'rejects unsupported signed fee identity %s',
    async (changes) => {
      const evidence = await fixture({ changes })
      await withRpc(evidence, async (client) => {
        await expect(FeeEvidence.resolve(client, evidence.receipt, evidence.payer)).rejects.toThrow(
          'Fee evidence',
        )
      })
    },
  )

  it('does not accept an unsigned envelope with a claimed RPC sender', async () => {
    const evidence = await fixture({ unsigned: true })
    await withRpc(evidence, async (client) => {
      await expect(FeeEvidence.resolve(client, evidence.receipt, evidence.payer)).rejects.toThrow(
        'signed root sender',
      )
    })
  })

  it('does not attribute an access-key fee to the access key instead of its root', async () => {
    const evidence = await fixture({ access: true })
    await withRpc(evidence, async (client) => {
      await expect(FeeEvidence.resolve(client, evidence.receipt, evidence.key)).rejects.toThrow(
        'signed root sender',
      )
    })
  })

  it.each(['eth_getTransactionByHash', 'eth_getRawTransactionByHash', 'eth_getBlockByNumber'])(
    'fails closed when %s is unavailable',
    async (method) => {
      const evidence = await fixture()
      await withRpc(
        evidence,
        async (client) => {
          await expect(
            FeeEvidence.resolve(client, evidence.receipt, evidence.payer),
          ).rejects.toThrow()
        },
        method,
      )
    },
  )

  it.skipIf(process.env.CARD_FEE_NATIVE !== '1')(
    'resolves an actual pinned Zone approval receipt without fee extensions',
    async () => {
      const privateKey = generatePrivateKey()
      const account = privateKeyToAccount(privateKey)
      const l1 = await Network.startL1(account.address)
      let zone: Network.Zone | undefined
      try {
        const userL1 = createClient({
          account,
          chain: Network.chain(l1.chainId, l1.rpcUrl),
          transport: http(l1.rpcUrl),
        })
        await userL1.faucet.fundSync({ account: account.address })
        // Zone dev provisioning grants token roles, so its initial token must belong to this admin.
        const initial = await userL1.token.createSync({
          name: 'Fee evidence fixture',
          symbol: 'FEE',
          currency: 'USD',
          quoteToken: Network.address.pathUsd,
          feeToken: Network.address.pathUsd,
        })
        zone = await Network.startZone({ l1, initialToken: initial.token, privateKey })
        await userL1.writeContractSync({
          address: zone.portal,
          abi: portalAbi,
          functionName: 'enableToken',
          args: [Network.address.pathUsd],
          feeToken: Network.address.pathUsd,
        })
        const store = Store.memory()
        const userZone = createClient({
          account,
          chain: { ...Network.chain(zone.chainId, zone.publicRpcUrl), sourceId: l1.chainId },
          transport: zoneHttp(zone.publicRpcUrl, { store, timeout: 60_000 }),
        })
        await userZone.zone.signAuthorizationToken({ account, zoneId: zone.zoneId, store })
        const depositHash = await userL1.zone.encryptedDeposit({
          amount: 100_000_000n,
          portalAddress: zone.portal,
          recipient: account.address,
          token: Network.address.pathUsd,
          zoneId: zone.zoneId,
        })
        const deposit = await userL1.waitForTransactionReceipt({ hash: depositHash })
        expect(deposit.status).toBe('success')
        await Actions.zone.waitForTempoBlock(userZone, {
          tempoBlockNumber: deposit.blockNumber,
          timeout: 180_000,
          pollingInterval: 500,
        })
        const hash = await userZone.writeContract({
          address: Network.address.pathUsd,
          abi: erc20Abi,
          functionName: 'approve',
          args: [Network.address.zoneOutbox, 1n],
          feeToken: Network.address.pathUsd,
        })
        const receipt = await userZone.waitForTransactionReceipt({ hash, timeout: 180_000 })
        expect(receipt.status).toBe('success')
        const identity = await FeeEvidence.resolve(userZone, receipt, account.address)
        expect(identity).toEqual({ feeToken: Network.address.pathUsd, feePayer: account.address })
        const rawReceipt = await userZone.request({
          method: 'eth_getTransactionReceipt',
          params: [hash],
        })
        const transaction = await userZone.request({
          method: 'eth_getTransactionByHash',
          params: [hash],
        })
        const raw = await userZone.request({
          method: 'eth_getRawTransactionByHash',
          params: [hash],
        })
        console.log(
          'PINNED_ZONE_FEE_EVIDENCE',
          JSON.stringify({ rawReceipt, transaction, raw, identity }),
        )
      } finally {
        await Promise.allSettled([zone?.container.stop(), l1.container.stop()])
      }
    },
    300_000,
  )
})

type Evidence = {
  payer: Address
  key: Address
  receipt: {
    transactionHash: Hex
    blockHash: Hex
    blockNumber: bigint
    gasUsed?: bigint
    effectiveGasPrice?: bigint
    feePayer?: Address
  }
  raw: string | null
  transaction: Record<string, unknown>
  block: Record<string, unknown>
}

type FeeOverrides = Pick<Transaction.TransactionSerializableTempo, 'feeToken' | 'feePayerSignature'>

async function fixture(
  options: {
    access?: boolean
    unsigned?: boolean
    changes?: FeeOverrides
  } = {},
): Promise<Evidence> {
  const root = privateKeyToAccount(generatePrivateKey())
  const key = generatePrivateKey()
  const signer = options.access ? Account.fromSecp256k1(key, { access: root.address }) : root
  const transaction: Transaction.TransactionSerializableTempo = {
    type: 'tempo',
    chainId: 1337,
    nonce: 1,
    nonceKey: 0n,
    calls: [{ to: other, data: '0x', value: 0n }],
    gas: 100_000n,
    maxFeePerGas: 20_000_000_000n,
    maxPriorityFeePerGas: 0n,
    feeToken: Network.address.pathUsd,
    ...options.changes,
  }
  const raw = options.unsigned
    ? await Transaction.serialize(transaction)
    : await signer.signTransaction(transaction, { serializer: Transaction.serialize })
  const hash = keccak256(raw)
  return {
    payer: root.address,
    key: privateKeyToAccount(key).address,
    receipt: { transactionHash: hash, blockHash, blockNumber: 1n },
    raw,
    transaction: { hash, blockHash, blockNumber: '0x1', from: root.address },
    block: { hash: blockHash, number: numberToHex(1n), transactions: [hash] },
  }
}

function rebindHash(evidence: Evidence, hash: Hex) {
  evidence.receipt.transactionHash = hash
  evidence.transaction.hash = hash
  evidence.block.transactions = [hash]
}

async function withRpc(
  evidence: Evidence,
  check: (client: Parameters<typeof FeeEvidence.resolve>[0]) => Promise<void>,
  unavailable?: string,
) {
  const server = createServer(async (request, response) => {
    let body = ''
    for await (const chunk of request) body += chunk
    const input = JSON.parse(body) as { id: number; method: string }
    const result: Record<string, unknown> = {
      eth_getTransactionByHash: evidence.transaction,
      eth_getRawTransactionByHash: evidence.raw,
      eth_getBlockByNumber: evidence.block,
    }
    response.setHeader('content-type', 'application/json')
    response.end(
      JSON.stringify({
        jsonrpc: '2.0',
        id: input.id,
        result: input.method === unavailable ? null : result[input.method],
      }),
    )
  })
  server.listen(0, '127.0.0.1')
  await once(server, 'listening')
  const address = server.address()
  if (!address || typeof address === 'string') throw new Error('RPC fixture did not bind')
  const url = `http://127.0.0.1:${address.port}`
  try {
    await check(
      createClient({ chain: Network.chain(1337, url), transport: http(url, { retryCount: 0 }) }),
    )
  } finally {
    server.closeAllConnections()
    await new Promise<void>((done, reject) =>
      server.close((error) => (error ? reject(error) : done())),
    )
  }
}
