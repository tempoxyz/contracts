import { mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { parseArgs } from 'node:util'
import { getAddress, isAddress } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'

import * as Devnet from './devnet.js'
import * as Config from './config.js'
import { assertBuildProvenanceUnchanged, prepareBuildProvenance } from './provenance.js'

/**
 * `pnpm devnet:deploy -- --out <dir> --eligible-account <address>`: the supported entry point for
 * external workflows that need a fresh Earn stack on an existing devnet. See
 * docs/deployment/e2e-environments.md#deploying-a-stack-for-another-workflow.
 */
const { values: args } = parseArgs({
  // pnpm forwards each `--` separator.
  args: process.argv.slice(2).filter((argument) => argument !== '--'),
  options: { out: { type: 'string' }, 'eligible-account': { type: 'string' } },
})
const out = args.out
const eligible = args['eligible-account']
if (!out) throw new Error('--out <directory> is required')
if (!eligible || !isAddress(eligible)) throw new Error('--eligible-account <address> is required')

// Resolve everything local before any chain write: a failure here must not leave a deployed stack
// with no record of its addresses, and the deployer key is single-use per L1.
const provenance = prepareBuildProvenance(Config.root)
const configuration = Devnet.configuration(process.env)
const user = getAddress(eligible)
// pnpm runs the script in localnet/, so a relative --out is the caller's.
const directory = resolve(process.env.INIT_CWD ?? process.cwd(), out)
mkdirSync(directory, { recursive: true })
const certifications = ['earn-source-revision', 'earn-build-provenance.json']
// Reusing an output directory must never attach an earlier run's certification to new addresses.
for (const name of certifications) rmSync(resolve(directory, name), { force: true })

const state = await Devnet.deploy({
  ...configuration,
  user,
  accessAdministrator: privateKeyToAccount(configuration.privateKeys.deployer).address,
  portalAccounts: [user],
})
const outputs: Record<
  Exclude<(typeof Devnet.outputFiles)[number], 'earn-source-revision'>,
  string | undefined
> = {
  'earn-input-token': state.alternateAsset,
  'earn-funding-helper': state.stablecoinFixture,
  'earn-token': state.earnShare,
  'earn-vault': state.earnVault,
  'earn-router': state.earnRouter,
}
// Chain writes cannot be undone: preserve recovery addresses even when the final input check fails.
for (const [name, value] of Object.entries(outputs)) {
  if (!value) continue
  writeFileSync(resolve(directory, name), value)
  console.log(`${name}: ${value}`)
}
if (!state.earnRouter) throw new Error('The devnet stack deployed no Earn router')
try {
  assertBuildProvenanceUnchanged(Config.root, provenance)
  writeFileSync(
    resolve(directory, 'earn-build-provenance.json'),
    `${JSON.stringify(provenance, null, 2)}\n`,
  )
  writeFileSync(resolve(directory, 'earn-source-revision'), provenance.sourceRevision)
  console.log(`earn-source-revision: ${provenance.sourceRevision}`)
} catch (error) {
  for (const name of certifications) rmSync(resolve(directory, name), { force: true })
  throw error
}
