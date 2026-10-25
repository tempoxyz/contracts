import { execFileSync } from 'node:child_process'
import { mkdirSync, writeFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { parseArgs } from 'node:util'
import { getAddress, isAddress } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'

import * as Devnet from './devnet.js'

/**
 * `pnpm devnet:deploy -- --out <dir> --eligible-account <address>`: the supported entry point for
 * external workflows that need a fresh Earn stack on an existing devnet. See
 * earn/docs/operations/e2e-environments.md#deploying-a-stack-for-another-workflow.
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
const configuration = Devnet.configuration(process.env)
const user = getAddress(eligible)
const revision = execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim()
// pnpm runs the script in localnet/, so a relative --out is the caller's.
const directory = resolve(process.env.INIT_CWD ?? process.cwd(), out)
mkdirSync(directory, { recursive: true })

const state = await Devnet.deploy({
  ...configuration,
  user,
  accessAdministrator: privateKeyToAccount(configuration.privateKeys.deployer).address,
  portalAccounts: [user],
})
if (!state.earnRouter) throw new Error('The devnet stack deployed no Earn router')

const outputs: Record<(typeof Devnet.outputFiles)[number], string> = {
  'earn-input-token': state.alternateAsset,
  'earn-funding-helper': state.stablecoinFixture,
  'earn-token': state.earnShare,
  'earn-vault': state.earnVault,
  'earn-router': state.earnRouter,
  'earn-source-revision': revision,
}
for (const [name, value] of Object.entries(outputs)) {
  writeFileSync(resolve(directory, name), value)
  console.log(`${name}: ${value}`)
}
