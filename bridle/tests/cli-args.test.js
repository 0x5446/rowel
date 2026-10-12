/**
 * What the command line does with what it does not expect.
 *
 * `bridle --version` once started a Bridle — the flag was ignored and the
 * command left standing was `start` — and, with no dsh running, launched a
 * dsh too. On a Mac mid-upgrade that dsh was the old one, and it held the
 * port the new one needed.
 */

import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

const cli = join(dirname(fileURLToPath(import.meta.url)), '..', 'lib', 'cli.js')
const version = JSON.parse(readFileSync(join(dirname(cli), '..', 'package.json'), 'utf8')).version

function bridle(...args) {
  const home = mkdtempSync(join(tmpdir(), 'rowel-cli-args-'))
  try {
    const run = spawnSync(process.execPath, [cli, ...args], {
      env: { PATH: process.env.PATH, HOME: home, ROWEL_HOME: join(home, 'rowel') },
      encoding: 'utf8',
      timeout: 10_000,
    })
    return { ...run, started: existsSync(join(home, 'rowel', 'runtime.json')) }
  } finally {
    rmSync(home, { recursive: true, force: true })
  }
}

test('--version and -v print the version and start nothing', () => {
  for (const spelling of ['--version', '-v', 'version']) {
    const run = bridle(spelling)
    assert.equal(run.status, 0, `${spelling}: ${run.stderr}`)
    assert.equal(run.stdout.trim(), version)
    assert.equal(run.started, false, `${spelling} started a Bridle`)
  }
})

test('--help prints the usage and starts nothing', () => {
  const run = bridle('--help')
  assert.equal(run.status, 0)
  assert.match(run.stdout, /bridle pair/u)
  assert.equal(run.started, false)
})

test('an option nothing reads is refused instead of ignored', () => {
  const run = bridle('--verison')
  assert.equal(run.status, 1)
  assert.match(run.stderr, /unknown option: --verison/u)
  assert.equal(run.started, false)
})
