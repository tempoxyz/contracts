import { execFileSync } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { basename, dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseArgs } from 'node:util'

import {
  address,
  engineDefinitions,
  hostedEnvironments,
  configuredTempoNetworkChain,
  object,
  type EngineKind,
  type HostedEnvironmentId,
} from '@tempoxyz/contracts/deployments'
import {
  assertFoundryVersion,
  configuredRpcTransport,
  envPrivateKey,
  loadEarnProfile,
  profileDeploymentPath,
  resolveProfilePath,
  rpcConfiguration,
  sourceVerificationCompilerArguments,
  verifyContractSource,
} from '@tempoxyz/contracts/deployments/node'
import { Deployment, localEngines } from 'localnet'
import {
  createPublicClient,
  encodeAbiParameters,
  erc20Abi,
  formatUnits,
  getAddress,
  isAddressEqual,
  keccak256,
  parseAbiParameters,
  type Address,
} from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { Addresses, createClient as createTempoClient } from 'viem/tempo'

import { loadProfileRuntimeConfig } from '../harness/environments.js'
import { TIMEOUT_MS } from '../harness/support/utils.js'
import {
  parseProfileFixtureRecord,
  profileFixtureContracts,
  profileFixturePath,
  type ProfileFixtureRecord,
} from './profile-fixture.js'

/**
 * `pnpm e2e:fixture --profile <id> --network <moderato|mainnet> [--broadcast]` provisions a hosted
 * test profile's fixture with localnet's fixture steps, one transaction each, owned by the deployer:
 *
 * - An engine whose hosted fixture runs over canonical PATHUSD gets its localnet venue and
 *   engine there; the source-verified, ready engine is named in the profile. Public profiles only.
 * - Any other gets a disposable stablecoin pair and funder, a venue with locked seed liquidity, and
 *   for a Zone profile the router's conversion pool; testnets only.
 *
 * It rewrites the profile, writes `fixture.json`, and removes a replaced deployment record;
 * `pnpm earn deploy` then deploys the stack. Without `--broadcast` it only prints the plan. The RPC
 * must report the profile's chain before anything is signed.
 */

const e2eRoot = dirname(dirname(fileURLToPath(import.meta.url)))
const repositoryRoot = dirname(e2eRoot)
// Earn's Foundry project: Forge steps and broadcasts resolve here.
const root = resolve(repositoryRoot, 'earn')
/** PATHUSD the deployer must hold for the fixture broadcasts, from the faucet where there is one. */
const minimumFeeBalance = 1_000_000n
const pathUsd = getAddress(Addresses.pathUsd)

const { values: args } = parseArgs({
  // pnpm forwards each `--` separator.
  args: process.argv.slice(2).filter((argument) => argument !== '--'),
  options: {
    profile: { type: 'string' },
    network: { type: 'string' },
    broadcast: { type: 'boolean', default: false },
    version: { type: 'string' },
    'replace-existing-deployment': { type: 'boolean', default: false },
  },
})
if (!args.profile) throw new Error('--profile is required')
if (!args.network || !Object.hasOwn(hostedEnvironments, args.network)) {
  throw new Error(`--network must be one of ${Object.keys(hostedEnvironments).join(', ')}`)
}
const network = args.network as HostedEnvironmentId
const replacementVersion = args.version === undefined ? undefined : Number(args.version)
if (
  replacementVersion !== undefined &&
  (!Number.isSafeInteger(replacementVersion) || replacementVersion <= 0)
) {
  throw new Error('--version must be a positive integer')
}

const chainId = hostedEnvironments[network].chainId
const profilePath =
  args.profile.includes('/') || args.profile.endsWith('.json')
    ? resolveProfilePath(args.profile)
    : resolve(repositoryRoot, 'profiles', args.profile, 'profile.json')
const original = object(JSON.parse(readFileSync(profilePath, 'utf8')), 'profile')
if (original.chainId !== chainId) {
  throw new Error(`Profile ${profilePath} targets chain ${original.chainId}, not ${network}`)
}
const profileId = String(original.id)
const engineKind = object(original.engine, 'profile.engine').kind as EngineKind
if (!Object.hasOwn(localEngines, engineKind)) throw new Error(`Unknown engine kind ${engineKind}`)
const { label } = engineDefinitions[engineKind]
const hostedFixture = localEngines[engineKind].hostedFixture
if (!hostedFixture) {
  throw new Error(`${label} fixtures are local only; no hosted fixture can be bootstrapped`)
}
const { overPathUsd, engineConstructorArgs } = hostedFixture
const zone = original.zone === undefined ? undefined : object(original.zone, 'profile.zone')
if (overPathUsd && zone) throw new Error(`A ${label} fixture supports public profiles only`)
if (!overPathUsd && !hostedEnvironments[network].testnet) {
  throw new Error(`Stablecoin fixtures are test-only; ${network} is not a testnet`)
}

const deploymentPath = profileDeploymentPath(profilePath)
if (existsSync(deploymentPath)) {
  if (!args['replace-existing-deployment']) {
    throw new Error(
      `${deploymentPath} already exists; pass --replace-existing-deployment for an intentional fresh deployment`,
    )
  }
  if (!replacementVersion || replacementVersion === original.version) {
    throw new Error('A fresh replacement requires a new explicit --version')
  }
}

const values = loadProfileRuntimeConfig(profilePath, profileId, ['DEPLOYER_PRIVATE_KEY'])
const tempo = rpcConfiguration('TEMPO', values, hostedEnvironments[network].rpcUrl)
const chain = configuredTempoNetworkChain({ ...hostedEnvironments[network], rpcUrl: tempo.url! })
const transport = configuredRpcTransport(tempo)
const client = createPublicClient({ chain, transport })
// Nothing is signed until the RPC proves it serves the selected chain.
const liveChainId = await client.getChainId()
if (liveChainId !== chainId) {
  throw new Error(`TEMPO_RPC_URL serves chain ${liveChainId}, not ${network} (${chainId})`)
}
const genesis = await client.getBlock({ blockNumber: 0n })

const privateKey = envPrivateKey(values, 'DEPLOYER_PRIVATE_KEY', { required: true })
const deployer = privateKeyToAccount(privateKey).address
// The profile's deployer is its record's, until a replacement removes it, and otherwise this key.
const recordedDeployer = existsSync(deploymentPath)
  ? address(object(JSON.parse(readFileSync(deploymentPath, 'utf8')), 'record').deployer, 'deployer')
  : deployer
if (!isAddressEqual(deployer, recordedDeployer)) {
  throw new Error(
    `DEPLOYER_PRIVATE_KEY signs as ${deployer}, not profile deployer ${recordedDeployer}`,
  )
}
const feeBalance = () =>
  client.readContract({
    address: pathUsd,
    abi: erc20Abi,
    functionName: 'balanceOf',
    args: [deployer],
  })
console.log(`Network · ${network} (chain ${chainId}, ${new URL(tempo.url!).host})`)
console.log(`Profile · ${profileId}${replacementVersion ? ` v${replacementVersion}` : ''}`)
console.log(`Deployer · ${deployer}`)
console.log(`Deployer PATHUSD · ${formatUnits(await feeBalance(), 6)}`)
console.log(
  `Plan · localnet ${engineDefinitions[engineKind].label} fixture steps over ${
    overPathUsd ? 'PATHUSD' : `a stablecoin pair${zone ? ' and conversion pool' : ''}`
  }, fixture.json`,
)
if (!args.broadcast) {
  console.log('Dry run: nothing was signed. Re-run with --broadcast to deploy.')
  process.exit(0)
}

assertFoundryVersion(root)
// The fixture's engine is source verified on the hosted network: resolve the compiler build the
// verifier needs before anything is broadcast.
sourceVerificationCompilerArguments(root)
if ((await feeBalance()) < minimumFeeBalance) {
  if (!hostedEnvironments[network].faucet) {
    throw new Error(`Fund ${deployer} with PATHUSD on ${network} before bootstrapping`)
  }
  await createTempoClient({ chain, transport }).faucet.fundSync({
    account: deployer,
    timeout: TIMEOUT_MS,
  })
}

// A fresh nonce gives every stablecoin pair its own token addresses and route ID.
const saltNonce = BigInt(Date.now())
const fixtures = await Deployment.provisionFixtures({
  account: deployer,
  broadcastDirectory: resolve(e2eRoot, '.local', `fixture-${profileId}-${Date.now()}`),
  chainId,
  client,
  privateKey,
  rpcUrl: tempo.authenticatedUrl!,
  engineKind,
  persistent: true,
  saltNonce,
  ...(overPathUsd ? { baseAsset: pathUsd } : {}),
  conversionPool: zone !== undefined,
  onStep: (name, address) => console.log(`✓ ${name}${address ? ` ${address}` : ''}`),
})
await Deployment.validateFixtures(client, engineKind, fixtures, deployer)

const updated: Record<string, unknown> = {
  ...original,
  ...(replacementVersion ? { version: replacementVersion } : {}),
  engine: localEngines[engineKind].profileEngine(fixtures.engine ?? fixtures.vault),
}
let fixture: Pick<ProfileFixtureRecord, 'saltNonce' | 'stablecoinFixture' | 'engineFixtures'>
if (fixtures.engine) {
  await verifyEngine(fixtures.engine)
  // The venue is the engine's; the fixture records its provenance beside the engine fixtures.
  fixture = { engineFixtures: { vault: fixtures.vault, ...fixtures.engineFixtures } }
} else {
  const { stablecoins, routerPool } = fixtures
  if (!stablecoins) throw new Error('The venue fixture deployed no stablecoin pair')
  const conversionPool = routerPool && {
    pool: routerPool.pool,
    oracle: routerPool.oracle,
    // Nonzero pool route identifier; the profile router binds this exact value.
    customerId: keccak256(
      encodeAbiParameters(parseAbiParameters('string, address, uint256'), [
        'tempo-earn.stablecoin-fixture.router.v1',
        deployer,
        saltNonce,
      ]),
    ),
  }
  if (zone && conversionPool) {
    updated.zone = {
      ...zone,
      router: {
        ...object(zone.router, 'profile.zone.router'),
        privateAsset: stablecoins.alternateAsset,
        pool: conversionPool.pool,
        customerId: conversionPool.customerId,
      },
    }
  }
  fixture = {
    saltNonce: saltNonce.toString(),
    stablecoinFixture: {
      baseAsset: fixtures.baseAsset,
      alternateAsset: stablecoins.alternateAsset,
      venue: fixtures.vault,
      ...(conversionPool ? { conversionPool } : {}),
      funder: stablecoins.funder,
    },
  }
}
const runtimeCodeHashes = Object.fromEntries(
  await Promise.all(
    profileFixtureContracts(fixture).map(async ([contract, address]) => {
      const code = await client.getCode({ address })
      if (!code || code === '0x') throw new Error(`${contract} has no runtime code at ${address}`)
      return [contract, keccak256(code)] as const
    }),
  ),
)

writeFileSync(profilePath, `${JSON.stringify(updated, null, 2)}\n`)
loadEarnProfile(profilePath)
const outputPath = profileFixturePath(profilePath)
mkdirSync(dirname(outputPath), { recursive: true })
const record = parseProfileFixtureRecord({
  version: 1,
  profileId,
  chainId,
  genesisHash: genesis.hash,
  generatedAt: new Date().toISOString(),
  ...fixture,
  runtimeCodeHashes,
  transactions: fixtures.receipts.map((receipt) => receipt.transactionHash),
})
writeFileSync(outputPath, `${JSON.stringify(record, null, 2)}\n`)
if (existsSync(deploymentPath)) rmSync(deploymentPath)
execFileSync('pnpm', ['exec', 'vp', 'fmt', profilePath, outputPath], {
  cwd: repositoryRoot,
  stdio: 'inherit',
})

console.log(`Updated profile: ${profilePath}`)
console.log(`Generated fixture: ${outputPath}`)
console.log(`Next: pnpm earn deploy ${relative(profilePath)}`)

/**
 * The lifecycle accepts an existing engine only with a source match against this checkout; it must
 * also be ready for deposits.
 */
async function verifyEngine(engine: Address) {
  if (!engineConstructorArgs) throw new Error(`No source verification for a ${label} engine`)
  const { engineContract, engineSource, inspectBindings } = engineDefinitions[engineKind]
  await verifyContractSource({
    chainId,
    environment: values,
    root,
    rpcUrl: tempo.authenticatedUrl!,
    address: engine,
    contract: `${engineSource}:${engineContract}`,
    constructorArgs: await engineConstructorArgs(client, engine),
  })
  await inspectBindings?.(client, engine, 'ready')
  console.log(`✓ ${engineContract} ${engine} is source verified and ready`)
}

function relative(path: string) {
  return path.startsWith(`${repositoryRoot}/`)
    ? path.slice(repositoryRoot.length + 1)
    : basename(path)
}
