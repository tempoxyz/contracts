import { parseArgs } from 'node:util'

type Selector = { mode: 'default' | 'all' | 'launch' } | { mode: 'case' | 'group'; value: string }

export type CaseSelection = Selector & { shard?: string | undefined }

type E2eArguments =
  | { mode: 'list' }
  | {
      /** Read-only hosted validation of one deployed profile; selects and runs no case. */
      mode: 'validate'
      profilePath: string
    }
  | {
      mode: 'run'
      local: boolean
      devnet: boolean
      profilePath?: string | undefined
      selection: CaseSelection
      variant?: string | undefined
    }

export function parseE2eArguments(argv: readonly string[]): E2eArguments {
  const { values, tokens } = parseArgs({
    // pnpm forwards each `--` separator.
    args: argv.filter((argument) => argument !== '--'),
    options: {
      list: { type: 'boolean' },
      'validate-only': { type: 'boolean' },
      local: { type: 'boolean' },
      devnet: { type: 'boolean' },
      all: { type: 'boolean', multiple: true },
      launch: { type: 'boolean', multiple: true },
      case: { type: 'string', multiple: true },
      group: { type: 'string', multiple: true },
      variant: { type: 'string' },
      'earn-file': { type: 'string' },
      shard: { type: 'string' },
    },
    strict: true,
    tokens: true,
  })
  const flags = new Set<string>()
  const selectors: Selector[] = []
  for (const token of tokens) {
    if (token.kind !== 'option') continue
    if (token.name === 'all' || token.name === 'launch') {
      selectors.push({ mode: token.name })
    } else if (token.name === 'case' || token.name === 'group') {
      selectors.push({ mode: token.name, value: optionValue(token.value, token.rawName) })
    } else {
      if (flags.has(token.rawName)) throw new Error(`${token.rawName} may be specified only once`)
      flags.add(token.rawName)
      if (token.value !== undefined) optionValue(token.value, token.rawName)
    }
  }
  const { local = false, devnet = false, variant, shard } = values
  const profilePath = values['earn-file']
  if (values.list) {
    // The environment scripts (`pnpm e2e:local -- --list`) add their flag; the list is the same.
    flags.delete('--local')
    flags.delete('--devnet')
    if (flags.size > 1 || selectors.length > 0) {
      throw new Error('--list cannot be combined with run arguments')
    }
    return { mode: 'list' }
  }
  if (values['validate-only']) {
    if (!profilePath) throw new Error('--validate-only requires --earn-file')
    if (flags.size > 2 || selectors.length > 0) {
      throw new Error('--validate-only accepts only --earn-file')
    }
    return { mode: 'validate', profilePath }
  }
  if (selectors.length > 1) {
    throw new Error('Use only one of --case, --group, --all, or --launch')
  }
  if (!local && variant) throw new Error('--variant is only valid with --local')
  if (devnet && (local || profilePath)) {
    throw new Error('--devnet deploys its own ERC-4626 stack; omit --local and --earn-file')
  }
  const selection: CaseSelection = { ...(selectors[0] ?? { mode: 'default' }), shard }
  return { mode: 'run', local, devnet, profilePath, selection, variant }
}

function optionValue(value: string | undefined, flag: string) {
  if (!value || value.startsWith('--')) throw new Error(`${flag} requires a value`)
  return value
}
