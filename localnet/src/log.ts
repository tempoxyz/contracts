const setupSteps = 6

export function setup(step: number, label: string, details: string[]) {
  const last = step === setupSteps
  const branch = last ? '└─' : '├─'
  const prefix = last ? '   ' : '│  '
  console.log(`${branch} [setup ${step}/${setupSteps}] ✓ ${label}`)
  for (const detail of details) console.log(`${prefix}${detail}`)
  if (!last) console.log('│')
}

export function address(value: string) {
  return abbreviate(value, 6, 4)
}

export function image(value: string) {
  const name = value.split('/').at(-1) ?? value
  const [repository, digest] = name.split('@sha256:')
  if (!repository || !digest) return name
  return `${repository}@sha256:${abbreviate(digest, 6, 6)}`
}

function abbreviate(value: string, start: number, end: number) {
  if (value.length <= start + end + 1) return value
  return `${value.slice(0, start)}…${value.slice(-end)}`
}
