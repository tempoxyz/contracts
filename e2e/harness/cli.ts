import { engineKinds } from '@tempoxyz/earn/deployments'
import { defaultEngineKind } from 'localnet'

import { parseE2eArguments } from './arguments.js'
import { runDevnet } from './devnet.js'
import { runHosted, validateHostedProfile } from './hosted.js'
import { runLocal } from './local.js'
import { loadProfile } from './profile.js'
import { readSourceState } from './results.js'
import { listE2eCases, runE2e } from './runner.js'

const args = parseE2eArguments(process.argv.slice(2))

if (args.mode === 'list') {
  listE2eCases()
} else if (args.mode === 'validate') {
  const loaded = loadProfile(args.profilePath)
  const { unverified } = await validateHostedProfile(loaded)
  console.log(`Hosted profile ${loaded.profile.id} passes read-only validation.`)
  for (const label of unverified) console.log(`${label}: not verified`)
} else {
  const source = readSourceState()
  const profile = args.profilePath ? loadProfile(args.profilePath) : undefined
  const run = { selection: args.selection, source }

  if (args.devnet) {
    const result = await runDevnet(source, (context, manifest) =>
      runE2e({ ...run, context, manifest }),
    )
    process.exitCode = result.failures > 0 ? 1 : 0
  } else if (args.local) {
    // A profile selects its own engine's variant; every engine kind is a local variant.
    const profileVariant = profile?.profile.engine.kind
    if (profileVariant && args.variant !== undefined && args.variant !== profileVariant) {
      throw new Error(
        `--variant ${args.variant} does not match the profile's ${profileVariant} engine`,
      )
    }
    const variant = profileVariant ?? args.variant ?? defaultEngineKind
    const variants =
      variant === 'all' ? engineKinds : engineKinds.filter((kind) => kind === variant)
    if (variants.length === 0) throw new Error(`Unknown local variant: ${args.variant}`)
    let failures = 0
    for (const engineKind of variants) {
      const result = await runLocal(source, engineKind, profile, (context, manifest, localized) =>
        runE2e({ ...run, context, manifest, profile: localized }),
      )
      failures += result.failures
    }
    process.exitCode = failures > 0 ? 1 : 0
  } else {
    if (!profile) {
      throw new Error(
        'Hosted E2E runs against a deployed profile: pass --earn-file profiles/<id>/profile.json',
      )
    }
    const result = await runHosted(profile, (context, manifest) =>
      runE2e({ ...run, context, manifest, profile }),
    )
    process.exitCode = result.failures > 0 ? 1 : 0
  }
}
