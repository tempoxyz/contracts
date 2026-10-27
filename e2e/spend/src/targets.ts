// Where the Zone E2E runs. Each target prepares an L1, a Zone and a deployed card program, then
// hands the same flow in run.ts the clients and accounts it needs.
//
// - local: a disposable L1 and Zone in Docker (network.ts). The run deploys a fresh program and,
//   as the Zone's admin, enables pathUSD, registers the program's ZoneRouter as a gateway and admits
//   its accounts, then runs the deployment preflight against it.
// - moderato: Tempo's testnet L1 and its hosted Zone 3, reached through Tempo API. The program is
//   deployed once (`--deploy`) and recorded in targets/moderato.json; a record without a settler
//   and router gets them from script/deploy/DeployZoneRouter.s.sol. A run changes the Zone's Portal
//   only with `--admit`: otherwise, when the router or the cardholder lacks the role the Portal
//   requires, the private steps report BLOCKED with the call the Zone administrator must make.
import { execFileSync } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { resolve } from 'node:path'
import {
  BaseError,
  concat,
  decodeFunctionResult,
  encodeFunctionData,
  getAddress,
  http,
  HttpRequestError,
  keccak256,
  TimeoutError,
  pad,
  parseAbi,
  zeroAddress,
  type Account as ViemAccount,
  type Address,
  type Hex,
  type Transport,
} from 'viem'
import { generatePrivateKey, privateKeyToAccount, type PrivateKeyAccount } from 'viem/accounts'
import { createClient as createTempoClient, Store, http as zoneHttp } from 'viem/tempo'
import { tempoModerato } from 'viem/tempo/chains'

import * as Network from './network.js'

/** Spend's Foundry project: Forge runs, artifacts and reports live here. */
export const root = resolve(new URL('.', import.meta.url).pathname, '../../../spend')
const e2eRoot = resolve(new URL('.', import.meta.url).pathname, '..')

export const portalAbi = parseAbi([
  'function setGateway(address account, bool allowed)',
  'function setAllowedAccount(address account, bool allowed)',
  'function isAccessEnforced() view returns (bool)',
  'function isGatewayOpen() view returns (bool)',
  'function isTokenEnabled(address token) view returns (bool)',
  'function hasRole(address account, uint8 role) view returns (bool)',
  'function enableToken(address token)',
  'function calculateDepositFee() view returns (uint128)',
  'function calculateBouncebackFee() view returns (uint128)',
])
const portalAdminAbi = parseAbi(['function admin() view returns (address)'])
const zoneFactoryAbi = parseAbi([
  'struct ZoneInfo { uint32 zoneId; address portal; bool accessMode; bool gatewayMode; address admin; address[] sequencers; uint8 threshold; address verifier; string rpcUrl; }',
  'function zones(uint32 id) view returns (ZoneInfo)',
  'function isZonePortal(address portal) view returns (bool)',
])
/** Portal roles, as `ZonePortal.Role` numbers them. */
const ROLE = { account: 2, callbackGateway: 3 } as const

export type Program = {
  factory: Address
  clone: Address
  /** The program's BridgeSettler: pays a router Spend through the clone. */
  settler: Address
  /** The factory-deployed ZoneRouter in Spend mode that lists `settler`: the Zone's gateway. */
  router: Address
  /** The ZoneRouterFactory that deployed `router`. */
  routerFactory: Address
  spenderId: Hex
  settlement: Address
  /** The program destination that pays private refunds, when the record has one. */
  programWallet?: Address
}

export type Prepared = {
  name: 'local' | 'moderato'
  l1: { chainId: number; rpcUrl: string; tracesCalls: boolean; blockTime?: string }
  zone: { id: number; chainId: number; portal: Address; batchIntervalBlocks?: number }
  program: Program
  cardholder: PrivateKeyAccount
  /** The admitted, customer-controlled Tempo account that receives returns the Zone rejects. */
  refundRecipient: Address
  /** Steps that only run where the Zone is disposable. */
  disposable: boolean
  /** A Tempo Earn vault the program allows and whose EarnShare the Zone has enabled, if any. */
  earn?: EarnTarget
  /** Why the private steps cannot run on this Zone, each with the fix; empty when they can. */
  blocked: string[]
  l1Public: PublicClient
  l1Wallet(account: ViemAccount): WalletClient
  /** A Zone client acting as `account`. `receipts` asks for one whose receipts keep every event. */
  zoneClient(account: ViemAccount, receipts?: boolean): Promise<WalletClient>
  close(): Promise<void>
}

/** A deployed Tempo Earn vault a Zone spend can redeem from. */
export type EarnTarget = {
  vault: Address
  /** The vault's asset: what a spend from Earn settles in. */
  asset: Address
  earnShare: Address
  /** Anyone can call its `fund(token, receiver, amount)` for the asset. */
  funder: Address
}

/** A Tempo chain: an L1, or a Zone with its parent L1 as `sourceId`. */
type TempoChain = ReturnType<typeof Network.chain>
const publicClient = (chain: TempoChain, transport: Transport) =>
  createTempoClient({ chain, transport })
const walletClient = (chain: TempoChain, transport: Transport, account: ViemAccount) =>
  createTempoClient({ account, chain, transport })

function zoneChain(
  chainId: number,
  rpcUrl: string,
  name: string,
  parentChainId: number,
): TempoChain {
  return { ...Network.chain(chainId, rpcUrl, name), sourceId: parentChainId }
}
export type PublicClient = ReturnType<typeof publicClient>
export type WalletClient = ReturnType<typeof walletClient>

type Step = (n: number, text: string) => void

/** Reads `e2e/spend/.env.<target>` beneath the process environment, which wins. */
export function loadEnv(target: string) {
  const file = resolve(e2eRoot, `.env.${target}`)
  const values: Record<string, string | undefined> = {}
  if (existsSync(file)) {
    for (const line of readFileSync(file, 'utf8').split('\n')) {
      const match = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/)
      if (match) values[match[1]!] = match[2]!.replace(/^['"]|['"]$/g, '')
    }
  }
  return { ...values, ...process.env } as Record<string, string | undefined>
}

function required(env: Record<string, string | undefined>, name: string, target: string): string {
  const value = env[name]?.trim()
  if (!value)
    throw new Error(
      `${name} is required for the ${target} target: set it in e2e/spend/.env.${target} or the environment`,
    )
  return value
}

/** Inputs a forge script reads and keys this run holds, which a forge run only gets explicitly. */
const FORGE_WITHHELD = [
  'FACTORY',
  'SPENDER_ID',
  'SETTLEMENT',
  'TOKEN',
  'ZONE_ID',
  'ROUTER',
  'ROUTER_FACTORY',
  'REFUND_RECIPIENT',
  'PROGRAM_WALLET',
  'VAULTS',
  'OUT',
  'DEPLOYER_PK',
  'DEPLOYER_PRIVATE_KEY',
  'CARDHOLDER_PRIVATE_KEY',
  'ZONE_ADMIN_PRIVATE_KEY',
  'TEMPO_API_KEY',
]

/**
 * The environment forge runs with: this process's, so proxies and Foundry settings still apply,
 * without stray script inputs or keys, plus the script's own inputs.
 */
export function forgeEnv(inputs: Record<string, string> = {}) {
  const env: Record<string, string> = {}
  for (const [name, value] of Object.entries(process.env)) {
    if (value !== undefined && !FORGE_WITHHELD.includes(name)) env[name] = value
  }
  return { ...env, ...inputs }
}

function deployProgram(
  rpcUrl: string,
  env: { deployerPk: Hex; settlement: Address; programWallet: Address; zoneId: number },
) {
  mkdirSync(resolve(root, 'reports'), { recursive: true })
  const out = `reports/zone-e2e-deploy-${env.zoneId}.json`
  execFileSync(
    'forge',
    [
      'script',
      'script/ZoneE2EDeploy.s.sol',
      '--rpc-url',
      rpcUrl,
      '--broadcast',
      '--slow',
      '--gas-estimate-multiplier',
      '105',
    ],
    {
      cwd: root,
      stdio: 'ignore',
      env: forgeEnv({
        DEPLOYER_PK: env.deployerPk,
        SETTLEMENT: env.settlement,
        PROGRAM_WALLET: env.programWallet,
        ZONE_ID: String(env.zoneId),
        OUT: out,
      }),
    },
  )
  return JSON.parse(readFileSync(resolve(root, out), 'utf8')) as Omit<Program, 'settlement'> & {
    zoneToken: Address
  }
}

/** The settler and Spend router script/deploy/DeployZoneRouter.s.sol deploys for a program. */
type RouterDeployment = Pick<Program, 'settler' | 'router' | 'routerFactory'>

/** Deploys a program's BridgeSettler and its Spend-mode ZoneRouter through the router factory. */
async function deployRouter(
  l1Public: PublicClient,
  rpcUrl: string,
  env: { deployerPk: Hex; factory: Address; spenderId: Hex; zoneId: number },
): Promise<RouterDeployment> {
  // The script reads the Zone factory, which forge runs only at the L1's hardfork.
  const foundryHardfork = await hardfork(l1Public)
  mkdirSync(resolve(root, 'reports'), { recursive: true })
  const out = `reports/zone-e2e-router-${env.zoneId}.json`
  execFileSync(
    'forge',
    [
      'script',
      'script/deploy/DeployZoneRouter.s.sol',
      '--rpc-url',
      rpcUrl,
      '--broadcast',
      '--slow',
      '--gas-estimate-multiplier',
      '105',
    ],
    {
      cwd: root,
      stdio: 'ignore',
      env: forgeEnv({
        FOUNDRY_HARDFORK: foundryHardfork,
        DEPLOYER_PK: env.deployerPk,
        FACTORY: env.factory,
        SPENDER_ID: env.spenderId,
        ZONE_ID: String(env.zoneId),
        OUT: out,
      }),
    },
  )
  const { settler, router, routerFactory } = JSON.parse(
    readFileSync(resolve(root, out), 'utf8'),
  ) as RouterDeployment
  return { settler, router, routerFactory }
}

/** The L1's active hardfork as forge names it, which forge needs to run the Zone factory. */
async function hardfork(l1Public: PublicClient) {
  const schedule = (await l1Public.request({ method: 'tempo_forkSchedule' } as never)) as {
    active: string
  }
  return `tempo:${schedule.active}`
}

/**
 * Runs script/deploy/Preflight.s.sol for `program` and returns its report lines. It fails when any
 * line is `todo`, so the private steps start only from a program the preflight accepts.
 */
async function preflight(
  l1Public: PublicClient,
  rpcUrl: string,
  inputs: {
    program: Program & { programWallet: Address }
    token: Address
    zoneId: number
    refundRecipient: Address
  },
) {
  const { program } = inputs
  let output: string
  try {
    output = execFileSync(
      'forge',
      ['script', 'script/deploy/Preflight.s.sol', '--rpc-url', rpcUrl],
      {
        cwd: root,
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'pipe'],
        env: forgeEnv({
          FOUNDRY_HARDFORK: await hardfork(l1Public),
          FACTORY: program.factory,
          SPENDER_ID: program.spenderId,
          SETTLEMENT: program.settlement,
          TOKEN: inputs.token,
          ZONE_ID: String(inputs.zoneId),
          ROUTER_FACTORY: program.routerFactory,
          ROUTER: program.router,
          REFUND_RECIPIENT: inputs.refundRecipient,
          PROGRAM_WALLET: program.programWallet,
        }),
      },
    )
  } catch (error) {
    const failed = error as { stdout?: string; stderr?: string }
    throw new Error(`Preflight failed:\n${failed.stdout ?? ''}${failed.stderr ?? ''}`)
  }
  const lines = output
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => /^(ok|todo) {2}/.test(line))
  const todo = lines.filter((line) => line.startsWith('todo'))
  if (lines.length === 0 || todo.length > 0) {
    throw new Error(
      `Preflight reports ${todo.length} todo (of ${lines.length} checks):\n${todo.join('\n') || output}`,
    )
  }
  return lines
}

// ---------------------------------------------------------------------------------------------
// local
// ---------------------------------------------------------------------------------------------

export async function local(step: Step): Promise<Prepared> {
  const zoneAdminPk = generatePrivateKey()
  const deployerPk = generatePrivateKey()
  const zoneAdmin = privateKeyToAccount(zoneAdminPk)
  const cardholder = privateKeyToAccount(generatePrivateKey())
  const refundRecipient = privateKeyToAccount(generatePrivateKey()).address
  const settlement = privateKeyToAccount(generatePrivateKey()).address
  const programWallet = privateKeyToAccount(generatePrivateKey()).address

  const l1 = await Network.startL1(zoneAdmin.address)
  let zone: Network.Zone | undefined
  try {
    step(1, `Tempo L1 at ${l1.rpcUrl} (chain ${l1.chainId})`)
    const l1Chain = Network.chain(l1.chainId, l1.rpcUrl)
    const l1Transport = http(l1.rpcUrl, { timeout: 60_000 })
    const l1Wallet = (account: ViemAccount) => walletClient(l1Chain, l1Transport, account)
    const l1Public = publicClient(l1Chain, l1Transport)
    for (const a of [
      zoneAdmin.address,
      privateKeyToAccount(deployerPk).address,
      cardholder.address,
    ]) {
      await l1Public.faucet.fundSync({ account: a, timeout: 180_000 })
    }

    const deployed = deployProgram(l1.rpcUrl, { deployerPk, settlement, programWallet, zoneId: 1 })
    const program = { ...deployed, settlement, programWallet }
    step(
      2,
      `Bridge program (clone ${program.clone}), BridgeSettler (${program.settler}) and Spend ZoneRouter (${program.router}) deployed on L1`,
    )

    zone = await Network.startZone({
      l1,
      initialToken: deployed.zoneToken,
      privateKey: zoneAdminPk,
    })
    step(3, `Tempo Zone 1 at ${zone.publicRpcUrl}, portal ${zone.portal}`)

    const admin = l1Wallet(zoneAdmin)
    const read = <T>(functionName: 'isAccessEnforced' | 'isGatewayOpen') =>
      l1Public.readContract({ address: zone!.portal, abi: portalAbi, functionName }) as Promise<T>
    const [accessEnforced, gatewayOpen, pathUsdEnabled] = await Promise.all([
      read<boolean>('isAccessEnforced'),
      read<boolean>('isGatewayOpen'),
      l1Public.readContract({
        address: zone.portal,
        abi: portalAbi,
        functionName: 'isTokenEnabled',
        args: [Network.address.pathUsd],
      }),
    ])
    const send = (
      functionName: 'enableToken' | 'setGateway' | 'setAllowedAccount',
      args: readonly unknown[],
    ) =>
      admin.writeContractSync({
        address: zone!.portal,
        abi: portalAbi,
        functionName,
        args,
        feeToken: Network.address.pathUsd,
      } as never)
    if (!pathUsdEnabled) await send('enableToken', [Network.address.pathUsd])
    if (!gatewayOpen) await send('setGateway', [program.router, true])
    // With the gateway open, the router deposits change back as an ordinary depositor, which an
    // access-enforced Portal admits only with the account role. The program wallet deposits refunds
    // into the Zone through the Portal, so it is admitted too.
    const admitted = [
      cardholder.address,
      refundRecipient,
      programWallet,
      ...(gatewayOpen ? [program.router] : []),
    ]
    if (accessEnforced) for (const a of admitted) await send('setAllowedAccount', [a, true])
    step(
      4,
      `Portal access ${accessEnforced ? 'closed loop' : 'open'}, gateway ${gatewayOpen ? 'open' : 'registered'}`,
    )

    const checks = await preflight(l1Public, l1.rpcUrl, {
      program,
      token: Network.address.pathUsd,
      zoneId: zone.zoneId,
      refundRecipient,
    })
    step(4, `Preflight: ${checks.length} checks ok, none todo`)

    const localZoneChain = zoneChain(zone.chainId, zone.rpcUrl, 'Local Tempo Zone', l1.chainId)
    const localZone = zone
    return {
      name: 'local',
      l1: { chainId: l1.chainId, rpcUrl: l1.rpcUrl, tracesCalls: true, blockTime: '500ms' },
      zone: {
        id: zone.zoneId,
        chainId: zone.chainId,
        portal: zone.portal,
        batchIntervalBlocks: Network.zoneBatchIntervalBlocks,
      },
      program,
      cardholder,
      refundRecipient,
      disposable: true,
      blocked: [],
      l1Public,
      l1Wallet,
      // The private RPC answers only requests carrying the account's authorization token, and strips
      // events such as `KeyAuthorized` from receipts, so receipt reads go to the public RPC.
      async zoneClient(account, receipts = false) {
        const store = Store.memory()
        const client = walletClient(
          localZoneChain,
          zoneHttp(receipts ? localZone.publicRpcUrl : localZone.rpcUrl, {
            store,
            timeout: 60_000,
          }),
          account,
        )
        await client.zone.signAuthorizationToken({ account, zoneId: localZone.zoneId, store })
        return client
      },
      async close() {
        await Promise.allSettled([localZone.container.stop(), l1.container.stop()])
      },
    }
  } catch (error) {
    await Promise.allSettled([zone?.container.stop(), l1.container.stop()])
    throw error
  }
}

// ---------------------------------------------------------------------------------------------
// moderato
// ---------------------------------------------------------------------------------------------

const moderato = {
  chainId: tempoModerato.id,
  rpcUrl: tempoModerato.rpcUrls.default.http[0],
  zone: { id: 3, chainId: 1_424_310_003 },
  // Tempo Earn's e2e-moderato stack on Zone 3 (tempoxyz/earn profiles/e2e-moderato).
  earn: {
    vault: '0x0eb6bc4711Bf400684Df14616e049F4b889eb025',
    asset: '0x20c00000000000000000000024c6653e25eaE22B',
    earnShare: '0x20C00000000000000000000054a015ca544260f8',
    funder: '0x0959330AF09aA996174FBd2Ad6938be58d6EfDBe',
  } satisfies EarnTarget,
}

/** Tries per synchronous L1 send, resending the same signed bytes after a transport failure. */
const SEND_ATTEMPTS = 3
/** JSON-RPC error codes viem's own retry treats as transient. */
const TRANSIENT_RPC_CODES = [-1, -32005, -32603]

const tsAbi = parseAbi([
  'function governorCall(bytes32 spenderId, bytes data)',
  'function publicGetCall(bytes data) returns (bytes)',
])
const moderatoRecord = resolve(e2eRoot, 'targets/moderato.json')

/** Tempo API's authenticated RPC route for a Tempo L1 or Zone chain. */
function tempoApiRpcUrl(chainId: number) {
  return `https://api.tempo.xyz/rpc/${chainId}`
}

/** A Portal role grant the router, cardholder, refund recipient or program wallet lacks. */
type Grant = { functionName: 'setGateway' | 'setAllowedAccount'; account: Address; what: string }

const safeAbi = parseAbi([
  'function getOwners() view returns (address[])',
  'function getThreshold() view returns (uint256)',
  'function execTransaction(address to, uint256 value, bytes data, uint8 operation, uint256 safeTxGas, uint256 baseGas, uint256 gasPrice, address gasToken, address refundReceiver, bytes signatures) payable returns (bool)',
])

/**
 * The Portal's administrator, as Tempo Earn's deployment tooling resolves it: the key is the Portal
 * admin, or the sole owner of a threshold-1 Safe that is. `send` grants roles either way, wrapping
 * each call in `execTransaction` with the owner's approved-by-sender signature when the admin is a
 * Safe, and simulates the batch before submitting it.
 */
async function zoneAdministrator(
  l1Public: PublicClient,
  l1Wallet: (account: ViemAccount) => WalletClient,
  portal: Address,
  privateKey: Hex,
) {
  const account = privateKeyToAccount(privateKey)
  const admin = getAddress(
    await l1Public.readContract({ address: portal, abi: portalAdminAbi, functionName: 'admin' }),
  )
  const safe = admin === account.address ? undefined : admin
  if (safe) {
    const [owners, threshold] = await Promise.all([
      l1Public
        .readContract({ address: safe, abi: safeAbi, functionName: 'getOwners' })
        .catch(() => [] as readonly Address[]),
      l1Public
        .readContract({ address: safe, abi: safeAbi, functionName: 'getThreshold' })
        .catch(() => 0n),
    ])
    if (threshold !== 1n || owners.length !== 1 || getAddress(owners[0]!) !== account.address) {
      throw new Error(
        `ZONE_ADMIN_PRIVATE_KEY ${account.address} does not control portal ${portal}: its admin ${admin} is neither that account nor a threshold-1 Safe it solely owns`,
      )
    }
  }
  const signature = concat([pad(account.address), pad('0x00'), '0x01'])
  const wrap = (call: { to: Address; data: Hex }) =>
    safe
      ? {
          to: safe,
          data: encodeFunctionData({
            abi: safeAbi,
            functionName: 'execTransaction',
            args: [call.to, 0n, call.data, 0, 0n, 0n, 0n, zeroAddress, zeroAddress, signature],
          }),
        }
      : call
  return {
    async send(grants: Grant[]) {
      const calls = grants.map((grant) =>
        wrap({
          to: portal,
          data: encodeFunctionData({
            abi: portalAbi,
            functionName: grant.functionName,
            args: [grant.account, true],
          }),
        }),
      )
      for (const call of calls) await l1Public.call({ account: account.address, ...call })
      await l1Public.faucet.fundSync({ account: account.address, timeout: 180_000 })
      const { receipt } = await sendL1Sync(l1Wallet(account), l1Public, calls)
      if (receipt.status !== 'success')
        throw new Error(`Portal role grant reverted: ${receipt.transactionHash}`)
    },
  }
}

export async function hosted(
  step: Step,
  options: { deploy: boolean; admit: boolean },
): Promise<Prepared> {
  const env = loadEnv('moderato')
  const apiKey = required(env, 'TEMPO_API_KEY', 'moderato')
  const cardholder = privateKeyToAccount(required(env, 'CARDHOLDER_PRIVATE_KEY', 'moderato') as Hex)

  const l1Chain = Network.chain(moderato.chainId, moderato.rpcUrl, 'Tempo Moderato')
  const l1Transport = http(moderato.rpcUrl, { timeout: 60_000, retryCount: 6, retryDelay: 250 })
  const l1Wallet = (account: ViemAccount) => walletClient(l1Chain, l1Transport, account)
  const l1Public = publicClient(l1Chain, l1Transport)
  const chainId = await l1Public.getChainId()
  if (chainId !== moderato.chainId)
    throw new Error(
      `${moderato.rpcUrl} serves chain ${chainId}, not Moderato (${moderato.chainId})`,
    )
  step(1, `Tempo Moderato at ${moderato.rpcUrl} (chain ${chainId})`)

  if (options.deploy) {
    const deployerPk = required(env, 'DEPLOYER_PRIVATE_KEY', 'moderato') as Hex
    await l1Public.faucet.fundSync({
      account: privateKeyToAccount(deployerPk).address,
      timeout: 180_000,
    })
    const settlement = privateKeyToAccount(generatePrivateKey()).address
    const programWallet = privateKeyToAccount(generatePrivateKey()).address
    const { zoneToken: _zoneToken, ...deployed } = deployProgram(moderato.rpcUrl, {
      deployerPk,
      settlement,
      programWallet,
      zoneId: moderato.zone.id,
    })
    // The deployer doubles as the program's refund account: admitted, and a key the test holds.
    const refundRecipient = privateKeyToAccount(deployerPk).address
    writeFileSync(
      moderatoRecord,
      `${JSON.stringify({ ...deployed, settlement, refundRecipient }, null, 2)}\n`,
    )
  }
  if (!existsSync(moderatoRecord))
    throw new Error(
      'targets/moderato.json is missing: deploy once with `pnpm zone:moderato --deploy`',
    )
  const record = JSON.parse(readFileSync(moderatoRecord, 'utf8')) as Omit<
    Program,
    keyof RouterDeployment
  > &
    Partial<RouterDeployment> & { refundRecipient: Address; receiver?: Address }
  // A record from before the router has no settler or router: deploy them for its program and
  // record them, dropping the retired receiver.
  if (!record.settler || !record.router || !record.routerFactory) {
    const deployerPk = required(env, 'DEPLOYER_PRIVATE_KEY', 'moderato') as Hex
    await l1Public.faucet.fundSync({
      account: privateKeyToAccount(deployerPk).address,
      timeout: 180_000,
    })
    const routed = await deployRouter(l1Public, moderato.rpcUrl, {
      deployerPk,
      factory: record.factory,
      spenderId: record.spenderId,
      zoneId: moderato.zone.id,
    })
    const { receiver: _receiver, ...rest } = record
    writeFileSync(moderatoRecord, `${JSON.stringify({ ...rest, ...routed }, null, 2)}\n`)
    Object.assign(record, routed)
    console.log(
      `    deployed: BridgeSettler ${routed.settler} and Spend ZoneRouter ${routed.router}`,
    )
  }
  const { refundRecipient, receiver: _receiver, ...recorded } = record
  const program: Program = { ...recorded, ...(record as RouterDeployment) }
  step(
    2,
    `Bridge program (clone ${program.clone}), BridgeSettler (${program.settler}) and Spend ZoneRouter (${program.router}) on Moderato`,
  )

  const zoneInfo = await l1Public.readContract({
    address: Network.address.zoneFactory,
    abi: zoneFactoryAbi,
    functionName: 'zones',
    args: [moderato.zone.id],
  })
  const portal = zoneInfo.portal
  const registered = await l1Public.readContract({
    address: Network.address.zoneFactory,
    abi: zoneFactoryAbi,
    functionName: 'isZonePortal',
    args: [portal],
  })
  if (!registered)
    throw new Error(
      `Zone ${moderato.zone.id} portal ${portal} is not registered with the Zone factory`,
    )
  const zoneUrl = tempoApiRpcUrl(moderato.zone.chainId)
  const zoneTransport = http(zoneUrl, {
    fetchOptions: { headers: { 'tempo-api-key': apiKey } },
    timeout: 60_000,
  })
  const hostedZoneChain = zoneChain(
    moderato.zone.chainId,
    zoneUrl,
    `Moderato Zone ${moderato.zone.id}`,
    moderato.chainId,
  )
  const zoneChainId = await publicClient(hostedZoneChain, zoneTransport).getChainId()
  if (zoneChainId !== moderato.zone.chainId)
    throw new Error(`Tempo API served Zone chain ${zoneChainId}, not ${moderato.zone.chainId}`)
  step(3, `Moderato Zone ${moderato.zone.id} through Tempo API, portal ${portal}`)

  const [accessEnforced, gatewayOpen] = await Promise.all([
    l1Public.readContract({ address: portal, abi: portalAbi, functionName: 'isAccessEnforced' }),
    l1Public.readContract({ address: portal, abi: portalAbi, functionName: 'isGatewayOpen' }),
  ])
  const hasRole = (account: Address, role: number) =>
    l1Public.readContract({
      address: portal,
      abi: portalAbi,
      functionName: 'hasRole',
      args: [account, role],
    })
  // The refund recipient is published on the L1 with every Zone return, so it must not be the
  // cardholder: it is one admitted account per program, as in production.
  if (getAddress(refundRecipient) === cardholder.address)
    throw new Error('the refund recipient must not be the cardholder')
  const missing = async () => {
    const grants: Grant[] = []
    if (!gatewayOpen && !(await hasRole(program.router, ROLE.callbackGateway))) {
      grants.push({
        functionName: 'setGateway',
        account: program.router,
        what: `router ${program.router} is not a callback gateway`,
      })
    }
    // With the gateway open, the router deposits change back as an ordinary depositor, which an
    // access-enforced Portal admits only with the account role.
    if (gatewayOpen && accessEnforced && !(await hasRole(program.router, ROLE.account))) {
      grants.push({
        functionName: 'setAllowedAccount',
        account: program.router,
        what: `router ${program.router} is not admitted`,
      })
    }
    if (accessEnforced && !(await hasRole(cardholder.address, ROLE.account))) {
      grants.push({
        functionName: 'setAllowedAccount',
        account: cardholder.address,
        what: `cardholder ${cardholder.address} is not admitted`,
      })
    }
    // The program wallet deposits refunds into the Zone through the Portal.
    const { programWallet } = program
    if (programWallet && accessEnforced && !(await hasRole(programWallet, ROLE.account))) {
      grants.push({
        functionName: 'setAllowedAccount',
        account: programWallet,
        what: `program wallet ${programWallet} is not admitted`,
      })
    }
    if (accessEnforced && !(await hasRole(refundRecipient, ROLE.account))) {
      grants.push({
        functionName: 'setAllowedAccount',
        account: refundRecipient,
        what: `refund recipient ${refundRecipient} is not admitted`,
      })
    }
    return grants
  }
  let grants = await missing()
  if (grants.length > 0 && options.admit) {
    const administrator = await zoneAdministrator(
      l1Public,
      l1Wallet,
      portal,
      required(env, 'ZONE_ADMIN_PRIVATE_KEY', 'moderato') as Hex,
    )
    await administrator.send(grants)
    for (const grant of grants)
      console.log(`    granted: ${grant.functionName}(${grant.account}, true) on portal ${portal}`)
    grants = await missing()
  }
  const blocked = grants.map(
    (grant) =>
      `${grant.what}: the Zone ${moderato.zone.id} admin must call ${grant.functionName}(${grant.account}, true) on portal ${portal} (or rerun with --admit and ZONE_ADMIN_PRIVATE_KEY)`,
  )
  step(
    4,
    `Portal access ${accessEnforced ? 'enforced' : 'open'}, gateway ${gatewayOpen ? 'open' : 'closed'}; ${blocked.length === 0 ? 'router, cardholder, refund recipient and program wallet have the roles they need' : `${blocked.length} role(s) missing`}`,
  )

  await l1Public.faucet.fundSync({ account: cardholder.address, timeout: 180_000 })
  // Earn is optional: a failed setup skips the Earn steps instead of the whole run.
  const earn = await prepareEarn(l1Public, l1Wallet, program, portal, moderato.earn, env).catch(
    (error) => {
      console.log(
        `    Earn: setup failed (${String((error as Error).message ?? error).split('\n')[0]})`,
      )
      return undefined
    },
  )
  step(
    4,
    earn
      ? `Earn vault ${earn.vault} allowed for the program, EarnShare enabled in the Zone`
      : 'Earn steps skipped: see above',
  )
  return {
    name: 'moderato',
    earn,
    l1: { chainId, rpcUrl: moderato.rpcUrl, tracesCalls: false },
    zone: { id: moderato.zone.id, chainId: moderato.zone.chainId, portal },
    program,
    cardholder,
    refundRecipient,
    disposable: false,
    blocked,
    l1Public,
    l1Wallet,
    // Tempo API's key authorizes the whole route, as Tempo Earn's hosted runs and app Worker use it,
    // so no per-account authorization token is signed.
    async zoneClient(account) {
      return walletClient(hostedZoneChain, zoneTransport, account)
    },
    async close() {},
  }
}

/**
 * Allows `earn.vault` for the program when it is not yet (the manager call, signed by the deployer,
 * which holds the test factory's manager role), and checks the Zone has EarnShare enabled. Returns
 * undefined, after saying why, when either is missing.
 */
async function prepareEarn(
  l1Public: PublicClient,
  l1Wallet: (account: ViemAccount) => WalletClient,
  program: Program,
  portal: Address,
  earn: EarnTarget,
  env: Record<string, string | undefined>,
): Promise<EarnTarget | undefined> {
  const enabled = await l1Public.readContract({
    address: portal,
    abi: portalAbi,
    functionName: 'isTokenEnabled',
    args: [earn.earnShare],
  })
  if (!enabled) {
    console.log(`    Earn: EarnShare ${earn.earnShare} is not enabled on portal ${portal}`)
    return undefined
  }
  const allowed = async () => {
    const { data } = await l1Public.call({
      to: program.clone,
      data: encodeFunctionData({
        abi: tsAbi,
        functionName: 'publicGetCall',
        args: [concat(['0x5453', '0x4756', earn.vault])],
      }),
    })
    if (!data) return false
    const encoded = decodeFunctionResult({ abi: tsAbi, functionName: 'publicGetCall', data })
    return encoded !== '0x' && BigInt(encoded) === 1n
  }
  if (!(await allowed())) {
    const deployerPk = env.DEPLOYER_PRIVATE_KEY as Hex | undefined
    if (!deployerPk) {
      console.log(
        `    Earn: vault ${earn.vault} is not allowed and DEPLOYER_PRIVATE_KEY is unset to allow it`,
      )
      return undefined
    }
    // Send, then wait: Moderato's gateway can drop a synchronous send that waits for its block.
    const hash = await l1Wallet(privateKeyToAccount(deployerPk)).writeContract({
      address: program.factory,
      abi: tsAbi,
      functionName: 'governorCall',
      args: [program.spenderId, concat(['0x5453', '0x5556', '0x01', earn.vault])],
      feeToken: Network.address.pathUsd,
    } as never)
    const receipt = await l1Public.waitForTransactionReceipt({ hash, timeout: 180_000 })
    if (receipt.status !== 'success') throw new Error(`the governance call ${hash} reverted`)
    console.log(`    allowed: Earn vault ${earn.vault} for the program`)
    if (!(await allowed()))
      throw new Error(`vault ${earn.vault} is still not allowed after the governance call`)
  }
  return earn
}

/**
 * Sends `calls` from `wallet`'s account with `eth_sendRawTransactionSync` and returns the receipt and
 * the milliseconds until it was in hand. Tempo's public RPC proxy ends any request after 1 s with a
 * 502 or 504, usually while the node keeps the transaction, so on those the node is polled briefly
 * for it and the receipt awaited by hash. When the node does not know the transaction after a
 * transport failure, the same signed bytes are resent, so a transaction is never sent twice.
 * `recovered` marks sends whose receipt was read back by hash: their time includes up to one 100 ms
 * poll.
 */
export async function sendL1Sync(
  wallet: WalletClient,
  l1Public: PublicClient,
  calls: readonly { to: Address; data: Hex }[],
) {
  const request = await wallet.prepareTransactionRequest({
    calls,
    feeToken: Network.address.pathUsd,
  } as never)
  const raw = await wallet.signTransaction(request as never)
  const hash = keccak256(raw)
  const known = () =>
    l1Public.getTransaction({ hash }).then(
      () => true,
      () => false,
    )
  /** Whether the node learns of the transaction within `ms`, polling every 250 ms. */
  const knownWithin = async (ms: number) => {
    for (const deadline = Date.now() + ms; ;) {
      if (await known()) return true
      if (Date.now() >= deadline) return false
      await new Promise((r) => setTimeout(r, 250))
    }
  }
  const start = performance.now()
  let recovered = false
  for (let attempt = 1; ; attempt++) {
    try {
      await wallet.request({ method: 'eth_sendRawTransactionSync', params: [raw] } as never, {
        retryCount: 0,
      })
      break
    } catch (error) {
      // Transport failures, and the JSON-RPC errors viem itself retries: unknown, limit exceeded, internal.
      const transport =
        error instanceof BaseError
          ? error.walk(
              (e) =>
                e instanceof HttpRequestError ||
                e instanceof TimeoutError ||
                (typeof (e as { code?: unknown }).code === 'number' &&
                  TRANSIENT_RPC_CODES.includes((e as { code: number }).code)),
            )
          : null
      const status = transport instanceof HttpRequestError ? transport.status : undefined
      // The proxy cut the wait short. The node normally has the transaction, but it may not yet
      // show it, or may never have received it, in which case it is resent below.
      const cutShort = status === 502 || status === 504
      // A resend the node rejects as already seen, or any failure after which it holds the transaction.
      if (attempt > 1 || transport) {
        if (await (cutShort ? knownWithin(3_000) : known())) {
          recovered = true
          break
        }
      }
      if (!transport || attempt === SEND_ATTEMPTS) throw error
      await new Promise((r) => setTimeout(r, 250 * 2 ** attempt))
    }
  }
  const answeredMs = Math.round(performance.now() - start)
  const receipt = await l1Public.waitForTransactionReceipt({
    hash,
    pollingInterval: 100,
    timeout: 60_000,
  })
  return { receipt, ms: recovered ? Math.round(performance.now() - start) : answeredMs, recovered }
}
