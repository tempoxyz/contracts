import { execFileSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { dirname, join, normalize } from 'node:path'
import { fileURLToPath } from 'node:url'
import { expect, test } from 'vitest'

const root = fileURLToPath(new URL('../', import.meta.url))
// Membership in the Git file list is case-sensitive, like Linux CI and GitHub, unlike macOS.
const files = execFileSync('git', ['ls-files', '--cached', '--others', '--exclude-standard'], {
  cwd: root,
  encoding: 'utf8',
})
  .split('\n')
  .filter((path) => path && !path.startsWith('lib/'))
const paths = new Set(
  files.flatMap((path) => path.split('/').map((_, i, parts) => parts.slice(0, i + 1).join('/'))),
)

/** GitHub's heading anchors of one Markdown file, outside code fences. */
const anchorCache = new Map<string, Set<string>>()
function anchors(path: string) {
  let found = anchorCache.get(path)
  if (found) return found
  found = new Set()
  const counts = new Map<string, number>()
  let fence = false
  for (const line of readFileSync(join(root, path), 'utf8').split('\n')) {
    if (/^\s*(```|~~~)/.test(line)) fence = !fence
    const heading = fence ? null : /^#{1,6}\s+(.*?)\s*#*\s*$/.exec(line)
    if (!heading) continue
    const slug = heading[1]!
      .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
      .replace(/<[^>]+>/g, '')
      .toLowerCase()
      .replace(/[^\p{L}\p{N}\s_-]/gu, '')
      .replace(/\s/g, '-')
    const count = counts.get(slug) ?? 0
    counts.set(slug, count + 1)
    found.add(count === 0 ? slug : `${slug}-${count}`)
  }
  anchorCache.set(path, found)
  return found
}

/** Why `target`, relative to `from`'s directory (or the root when `fromRoot`), does not resolve. */
function broken(from: string, target: string, fromRoot = false) {
  const [pathPart = '', anchor] = target.split('#')
  const path = pathPart
    ? normalize(join(fromRoot ? '' : dirname(from), decodeURI(pathPart))).replace(/\/$/, '')
    : from
  if (!paths.has(path)) return `${target} does not exist`
  if (anchor && path.endsWith('.md') && !anchors(path).has(anchor))
    return `${target} has no #${anchor}`
  return undefined
}

test('local documentation links and anchors resolve', () => {
  const problems: string[] = []
  for (const file of files.filter((path) => /\.(md|tsx?|ya?ml|sol|json|toml)$/.test(path))) {
    let fence = false
    readFileSync(join(root, file), 'utf8')
      .split('\n')
      .forEach((line, index) => {
        const report = (problem: string | undefined) =>
          problem && problems.push(`${file}:${index + 1}: ${problem}`)
        if (!file.endsWith('.md')) {
          // Source comments and messages cite docs by repository path.
          for (const [, target] of line.matchAll(
            /(?<![\w/.-])(?:\.\.\/)*(docs\/[\w./-]+\.md(?:#[\w-]+)?)/g,
          ))
            report(broken(file, target!, true))
          return
        }
        if (/^\s*(```|~~~)/.test(line)) fence = !fence
        if (fence) return
        for (const [, target] of line.matchAll(/\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g))
          if (target && !/^(https?:|mailto:)/.test(target)) report(broken(file, target))
        for (const [, target] of line.matchAll(/\b(?:src|srcset|href)="([^"#][^"]*)"/g))
          if (!/^https?:/.test(target!)) report(broken(file, target!))
      })
  }
  expect(problems).toEqual([])
})
