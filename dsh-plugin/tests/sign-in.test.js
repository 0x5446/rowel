/**
 * Inside dsh 0.2, the plugin signs its Bridle in with what dsh hands it.
 *
 * dsh injects two services into plugins that ask: `webServer.port`, where it
 * really answers, and `connection.authenticatedUrl()`, which carries the launch
 * token. The plugin trades the token on loopback and binds its Bridle to that
 * port. The fake dsh here has only the sign-in door; the fake context hands the
 * services over the way dsh's loader calls an `inject` callback.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { createServer } from 'node:http'
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { apply } from '../lib/index.js'

process.env.ROWEL_HOME = mkdtempSync(join(tmpdir(), 'rowel-plugin-signin-'))
process.env.ROWEL_INSTANCES = join(process.env.ROWEL_HOME, 'instances-index.json')

const TOKEN = 'plugin-token'
const COOKIE = 'dsh-auth-plugin=v1.body.sig'

function fakeDsh() {
  const server = createServer((request, response) => {
    const url = new URL(request.url, 'http://x')
    if (request.method === 'GET' && url.pathname === '/' && url.searchParams.get('token') === TOKEN) {
      response.writeHead(303, { location: './', 'set-cookie': `${COOKIE}; Path=/; HttpOnly` })
      response.end()
      return
    }
    // Signed in, the 0.1 methods the Bridle core still asks for are simply
    // gone (404), as on a real dsh 0.2. A 401 here would mean "cookie
    // refused", and the Bridle would rightly drop it.
    if (request.headers.cookie === COOKIE) {
      response.writeHead(404, { 'content-type': 'text/plain' })
      response.end('not found')
      return
    }
    response.writeHead(401, { 'content-type': 'text/plain' })
    response.end('dsh web authentication required')
  })
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => { resolve({ port: server.address().port, close: () => server.close() }) })
  })
}

async function until(read, timeoutMs = 10_000) {
  const deadline = Date.now() + timeoutMs
  for (;;) {
    try {
      const value = read()
      if (value !== undefined) return value
    } catch {
      // Not written yet.
    }
    if (Date.now() > deadline) return undefined
    await new Promise((resolve) => { setTimeout(resolve, 100) })
  }
}

test('the plugin trades dsh\'s token on loopback and binds to the port dsh reports', async (t) => {
  const dsh = await fakeDsh()
  t.after(() => dsh.close())
  const base = `http://127.0.0.1:${String(dsh.port)}`
  // Relay off and a dead dsh address in the state file: if the plugin did not
  // take the injected port, the runtime snapshot would still say port 9.
  writeFileSync(join(process.env.ROWEL_HOME, 'bridle.json'), JSON.stringify({
    version: 1,
    deviceId: 'signin-test',
    privateKey: Buffer.alloc(32).toString('base64url'),
    signingKey: Buffer.alloc(64).toString('base64url'),
    machineName: 'signin-test',
    relayUrl: '',
    dshUrl: 'http://127.0.0.1:9',
    peers: [],
  }))

  const handlers = []
  const errors = []
  apply({
    on: (event, handler) => { handlers.push(handler) },
    logger: { error: (message) => errors.push(message) },
    inject: (deps, callback) => {
      assert.deepEqual(deps, ['connection', 'webServer'])
      callback({
        webServer: { port: dsh.port },
        // What dsh does: the token added to whatever base it is given.
        connection: { authenticatedUrl: (url) => `${url}/?token=${TOKEN}` },
      })
    },
  }, { noDirect: true })
  t.after(() => { for (const handler of handlers) handler() })

  const cookies = await until(() => {
    const saved = JSON.parse(readFileSync(join(process.env.ROWEL_HOME, 'secrets', 'dsh-cookies.json'), 'utf8'))
    return saved[`127.0.0.1:${String(dsh.port)}`]
  })
  assert.equal(cookies, COOKIE, errors.join('\n'))
  const bound = await until(() => {
    const runtime = JSON.parse(readFileSync(join(process.env.ROWEL_HOME, 'runtime.json'), 'utf8'))
    return runtime.dshUrl === base ? runtime.dshUrl : undefined
  })
  assert.equal(bound, base, 'the Bridle stayed bound to the configured address instead of where dsh answers')
  assert.deepEqual(errors, [])
})

test('services that misbehave are logged, not thrown into dsh', () => {
  const errors = []
  const handlers = []
  assert.doesNotThrow(() => {
    apply({
      on: (event, handler) => { handlers.push(handler) },
      logger: { error: (message) => errors.push(message) },
      inject: (deps, callback) => { callback({ webServer: undefined, connection: undefined }) },
    }, { noDirect: true })
  })
  for (const handler of handlers) handler()
  assert.ok(errors.some(message => message.includes('misbehaved')), errors.join('\n'))
})
