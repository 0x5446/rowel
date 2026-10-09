/**
 * Starting dsh 0.2 and signing in to it, end to end.
 *
 * Bridle reads the token from the line a launched dsh prints, through a
 * private file that must not outlive the launch, and trades it on loopback —
 * never at the address the line shows (`fixtures/fake-dsh-02.js` prints a
 * reverse-proxy one, as dsh 0.2.1 does with a `publicUrl`).
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { createServer } from 'node:net'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const rowelHome = mkdtempSync(join(tmpdir(), 'rowel-launch-'))
process.env['ROWEL_HOME'] = rowelHome
test.after(() => { rmSync(rowelHome, { recursive: true, force: true }) })

const { cookieFor, ensureDsh } = await import('@rowel/bridle')

const FAKE = join(dirname(fileURLToPath(import.meta.url)), 'fixtures', 'fake-dsh-02.js')

function freePort() {
  return new Promise((resolve) => {
    const server = createServer()
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address()
      server.close(() => { resolve(port) })
    })
  })
}

test('a dsh bridle starts is signed in to over loopback, and its token is not left on disk', async (t) => {
  // A file a killed Bridle left behind, holding a token that may still be live.
  const secrets = join(rowelHome, 'secrets')
  mkdirSync(secrets, { recursive: true, mode: 0o700 })
  writeFileSync(join(secrets, 'dsh-launch-999999.log'), 'dsh web: http://127.0.0.1:1/?token=old\n', { mode: 0o600 })

  const port = await freePort()
  const url = `http://127.0.0.1:${String(port)}`
  t.after(() => fetch(`${url}/quit`).catch(() => {}))

  const found = await ensureDsh({
    preferred: url,
    pinned: true,
    autoStart: true,
    command: process.execPath,
    args: [FAKE, '--port', String(port)],
  })

  assert.equal(found.url, url)
  assert.equal(found.launched, true)
  assert.deepEqual(found.identity, { kind: 'signed-in', version: '0.2.1-alpha.1' })
  assert.equal(cookieFor(url), 'dsh-auth-fake=v1.body.sig')
  assert.deepEqual(readdirSync(secrets).filter(name => name.startsWith('dsh-launch-')), [],
    'a file holding a launch token outlived the launch')
})
