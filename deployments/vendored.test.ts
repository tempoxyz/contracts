import { createHash } from 'node:crypto'
import { readdirSync, readFileSync } from 'node:fs'
import { join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'
import { expect, test } from 'vitest'

const vendor = fileURLToPath(new URL('../vendor/', import.meta.url))

/** Every file under `directory`, as a path relative to `vendor/`. */
function files(directory: string): string[] {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = join(directory, entry.name)
    return entry.isDirectory() ? files(path) : [relative(vendor, path)]
  })
}

test('vendored Bridge files match the SHA-256 hashes VENDORED.md records', () => {
  const recorded = Object.fromEntries(
    [
      ...readFileSync(join(vendor, 'VENDORED.md'), 'utf8').matchAll(
        /^\| `(bridge\/[^`]+)` +\| `([0-9a-f]{64})` +\|$/gm,
      ),
    ].map(([, path, hash]) => [path!, hash!]),
  )
  const actual = Object.fromEntries(
    files(join(vendor, 'bridge')).map((path) => [
      path,
      createHash('sha256')
        .update(readFileSync(join(vendor, path)))
        .digest('hex'),
    ]),
  )
  expect(Object.keys(actual).length).toBeGreaterThan(0)
  expect(actual).toEqual(recorded)
})
