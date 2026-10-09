/**
 * `bridle plugin install|uninstall`: one entry in the person's own patch file.
 *
 * The file belongs to the person, so the rules are about restraint: add to the
 * two shapes a real file has (the `[]` dsh writes, or a block list), leave any
 * other shape alone with instructions, remove only what was added, and leave a
 * file dsh can still read every time.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { installPlugin, patchFile, uninstallPlugin } from '@rowel/bridle'

/** What dsh 0.2 writes into a fresh profile, verbatim. */
const FRESH = `# Your patch layer for this dsh profile, applied after every bundle layer:
# a top-level YAML array of loader patch entries (id-targeted config
# overrides, disables, and insert lists; \`!!js\` expressions allowed).
[]
`

function home(t, content) {
  const root = mkdtempSync(join(tmpdir(), 'rowel-plugin-'))
  t.after(() => { rmSync(root, { recursive: true, force: true }) })
  mkdirSync(join(root, 'profiles', 'web'), { recursive: true })
  if (content !== undefined) writeFileSync(patchFile(root), content)
  return root
}

const PLUGIN = '/Users/someone/.rowel/src/dsh-plugin/lib/index.js'

test('a fresh profile gets the entry in place of its empty list', (t) => {
  const root = home(t, FRESH)
  assert.equal(installPlugin(root, PLUGIN).result, 'added')
  const text = readFileSync(patchFile(root), 'utf8')
  assert.ok(text.startsWith('# Your patch layer'), 'the comment header is the person\'s and stays')
  assert.ok(!text.includes('[]'), 'a block entry after `[]` is not YAML')
  assert.ok(text.includes(`- insert:\n    - id: rowel-bridle\n      name: "${PLUGIN}"`))
})

test('a block list gets the entry appended, and its own entries kept', (t) => {
  const mine = '- id: web\n  config:\n    searchProvider: exa\n'
  const root = home(t, mine)
  assert.equal(installPlugin(root, PLUGIN).result, 'added')
  const text = readFileSync(patchFile(root), 'utf8')
  assert.ok(text.startsWith(mine))
  assert.ok(text.endsWith(`      name: "${PLUGIN}"\n`))
})

test('installing twice changes nothing; a moved checkout updates the path', (t) => {
  const root = home(t, FRESH)
  installPlugin(root, PLUGIN)
  const once = readFileSync(patchFile(root), 'utf8')
  assert.equal(installPlugin(root, PLUGIN).result, 'unchanged')
  assert.equal(readFileSync(patchFile(root), 'utf8'), once)
  assert.equal(installPlugin(root, '/elsewhere/index.js').result, 'updated')
  const text = readFileSync(patchFile(root), 'utf8')
  assert.ok(text.includes('name: "/elsewhere/index.js"'))
  assert.equal(text.split('id: rowel-bridle').length, 2, 'one entry, not two')
})

test('a shape bridle does not edit is left alone, with the lines to add', (t) => {
  const flow = '[{ id: web, config: { a: 1 } }]\n'
  const root = home(t, flow)
  const outcome = installPlugin(root, PLUGIN)
  assert.equal(outcome.result, 'manual')
  assert.ok(outcome.lines.includes('id: rowel-bridle'))
  assert.equal(readFileSync(patchFile(root), 'utf8'), flow)
})

test('a profile dsh never created is an error, not a file made up from nothing', (t) => {
  const root = home(t)
  assert.throws(() => installPlugin(root, PLUGIN))
})

test('uninstall takes out exactly what install put in, and leaves valid YAML', (t) => {
  const root = home(t, FRESH)
  installPlugin(root, PLUGIN)
  assert.equal(uninstallPlugin(root).result, 'removed')
  const text = readFileSync(patchFile(root), 'utf8')
  assert.ok(!text.includes('rowel-bridle'))
  assert.ok(/^\[\]$/mu.test(text), 'an emptied file goes back to the empty list dsh can read')

  const mine = '- id: web\n  config:\n    searchProvider: exa\n'
  const other = home(t, mine)
  installPlugin(other, PLUGIN)
  uninstallPlugin(other)
  assert.equal(readFileSync(patchFile(other), 'utf8'), mine)
  assert.equal(uninstallPlugin(other).result, 'unchanged')
})
