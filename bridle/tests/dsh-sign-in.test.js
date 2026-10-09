/**
 * Signing in to dsh 0.2, and telling it apart from 0.1.
 *
 * dsh 0.2 refuses all of `/api` — loopback included — without a cookie that
 * only its launch token buys. The fakes below behave the way dsh does at the
 * door (see docs/dsh-0.2-protocol.md §1): `GET /?token=` answers 303 with a
 * `dsh-auth-…` cookie, every API call without that cookie answers 401, and
 * `pluginManager/listBundles` names the version once signed in. The legacy
 * fake answers its dotted 0.1 methods to anyone.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { createServer } from 'node:http'
import { mkdtempSync, rmSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

// Before the package loads: the cookie store lives under ROWEL_HOME.
const rowelHome = mkdtempSync(join(tmpdir(), 'rowel-signin-'))
process.env['ROWEL_HOME'] = rowelHome
test.after(() => { rmSync(rowelHome, { recursive: true, force: true }) })

const {
  cookieFor, exchangeToken, forgetCookie, identifyDsh, probeDsh, rememberCookie, speaksCurrentApi, tokenFrom,
} = await import('@rowel/bridle')

const TOKEN = 'launch-token-1'
const COOKIE = 'dsh-auth-abc=v1.body.sig'

/** A dsh 0.2 at the door. */
function currentDsh(version = '0.2.0-rc.2') {
  return listen((request, response) => {
    const url = new URL(request.url, 'http://x')
    if (request.method === 'GET' && url.pathname === '/') {
      if (url.searchParams.get('token') !== TOKEN) return reply(response, 401, 'text/plain', 'dsh web authentication required')
      response.writeHead(303, { location: './', 'set-cookie': `${COOKIE}; Max-Age=2592000; Path=/; HttpOnly; SameSite=Strict` })
      return response.end()
    }
    if (request.headers.cookie !== COOKIE) return reply(response, 401, 'text/plain', 'unauthorized')
    if (url.pathname === '/api/pluginManager/listBundles') {
      return reply(response, 200, 'application/json', JSON.stringify({
        type: 'server-response', rpcId: 'r', result: { ok: true, value: [{ name: '@deepseek-ai/dsh-web-app', version }, { name: '@deepseek-ai/dsh-base', version }] },
      }))
    }
    return reply(response, 404, 'text/plain', 'not found')
  })
}

/** A dsh 0.1.1: no door at all. */
function legacyDsh() {
  return listen((request, response) => {
    request.resume()
    request.on('end', () => {
      reply(response, 200, 'application/json', JSON.stringify({ type: 'server-response', rpcId: 'r', result: { ok: true, value: { items: [] } } }))
    })
  })
}

function listen(handler) {
  const server = createServer(handler)
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => {
      resolve({ url: `http://127.0.0.1:${server.address().port}`, close: () => server.close() })
    })
  })
}

function reply(response, status, type, body) {
  response.writeHead(status, { 'content-type': type })
  response.end(body)
}

test('only the token is taken from the printed line, whatever address it shows', () => {
  assert.equal(tokenFrom('dsh web: http://127.0.0.1:3080/?token=abc_-1'), 'abc_-1')
  // 0.2.1 with a publicUrl prints a proxy address; the token is all we use.
  assert.equal(tokenFrom('dsh web: https://app.example/ui/?token=xyz'), 'xyz')
  assert.equal(tokenFrom('dsh web: http://127.0.0.1:3080/ (LAN: http://10.0.0.2:3080/?token=t)'), undefined,
    'a line whose first URL has no token must not borrow one from the LAN suffix')
  assert.equal(tokenFrom('dsh web: opening the default browser; pass --no-open to disable'), undefined)
})

test('a token buys the cookie; a wrong one is refused out loud', async (t) => {
  const dsh = await currentDsh()
  t.after(() => dsh.close())
  assert.equal(await exchangeToken(dsh.url, TOKEN), COOKIE)
  await assert.rejects(exchangeToken(dsh.url, 'stale'), /refused the token \(HTTP 401\)/u)
  await assert.rejects(exchangeToken('http://example.com', TOKEN), /loopback/u, 'the token must never leave the machine')
})

test('dsh 0.1.1 is recognised by answering without a cookie', async (t) => {
  const dsh = await legacyDsh()
  t.after(() => dsh.close())
  assert.deepEqual(await identifyDsh(dsh.url), { kind: 'legacy' })
})

test('dsh 0.2 is locked without a cookie, and names its version with one', async (t) => {
  const dsh = await currentDsh()
  t.after(() => dsh.close())
  assert.deepEqual(await identifyDsh(dsh.url), { kind: 'locked' })
  assert.deepEqual(await identifyDsh(dsh.url, 'dsh-auth-abc=expired'), { kind: 'locked' },
    'a refused cookie is "sign in again", not a version')
  assert.deepEqual(await identifyDsh(dsh.url, COOKIE), { kind: 'signed-in', version: '0.2.0-rc.2' })
})

test('something that is not dsh is not identified as one', async (t) => {
  const other = await listen((request, response) => { reply(response, 404, 'text/html', '<h1>nope</h1>') })
  t.after(() => other.close())
  const identity = await identifyDsh(other.url)
  assert.equal(identity.kind, 'unknown')
})

test('a locked dsh still counts as found, so bridle does not start a second one on its port', async (t) => {
  // The bug this guards: the old probe asked `host.describe`, read dsh 0.2's
  // 401 as "nothing here", and launched another dsh onto the same port.
  const dsh = await currentDsh()
  t.after(() => dsh.close())
  assert.equal(await probeDsh(dsh.url, true), dsh.url)
})

test('0.2 and later speak the current API; the 0.1 transitions do not', () => {
  for (const version of ['0.2.0-rc.2', '0.2.0', '0.2.1-alpha.1', '0.10.0', '1.0.0']) {
    assert.equal(speaksCurrentApi(version), true, version)
  }
  for (const version of ['0.1.1-rc.2', '0.1.7', '0.1.7-rc.2', 'nonsense', '']) {
    assert.equal(speaksCurrentApi(version), false, version)
  }
})

test('cookies are kept per address, privately, and dropped when refused', () => {
  rememberCookie('http://127.0.0.1:3092', COOKIE)
  assert.equal(cookieFor('http://127.0.0.1:3092/'), COOKIE)
  assert.equal(cookieFor('http://127.0.0.1:3093'), undefined, 'another port is another dsh')
  assert.equal(cookieFor('http://localhost:3092'), undefined, 'dsh binds the cookie to the exact Host')
  const file = join(rowelHome, 'secrets', 'dsh-cookies.json')
  assert.equal(statSync(file).mode & 0o777, 0o600, 'a cookie is a credential')
  forgetCookie('http://127.0.0.1:3092')
  assert.equal(cookieFor('http://127.0.0.1:3092'), undefined)
})
