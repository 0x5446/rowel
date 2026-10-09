/**
 * The one rule this client must never bend: it talks to a harness on this
 * machine, over loopback, and nowhere else. A Bridle pointed at a remote
 * address would be handing a shell — and dsh's sign-in cookie — to whoever
 * answers.
 */

import assert from 'node:assert/strict'
import { createServer as createHttpServer } from 'node:http'
import { createServer } from 'node:net'
import test from 'node:test'
import { DshClient, assertLoopback } from '../lib/index.js'

test('loopback addresses in every spelling are accepted', () => {
  for (const url of ['http://127.0.0.1:3080', 'http://localhost:8791', 'http://127.7.7.7:1234', 'http://[::1]:3080']) {
    assert.doesNotThrow(() => assertLoopback(url), url)
  }
})

test('anything off this machine is refused', () => {
  for (const url of ['http://192.168.1.10:3080', 'https://dsh.example.com', 'http://0.0.0.0:3080', 'http://10.0.0.1:3080']) {
    assert.throws(() => assertLoopback(url), /must be loopback/u, url)
  }
})

test('the client refuses to be constructed against a remote harness', () => {
  assert.throws(() => new DshClient({ baseUrl: 'http://example.com' }), /must be loopback/u)
})

test('a failed call folds into the error branch rather than rejecting', async () => {
  const client = new DshClient({ baseUrl: 'http://127.0.0.1:1', requestTimeoutMs: 1_000 })
  const result = await client.call('session/list', { _request: {} })
  assert.equal(result.ok, false)
  assert.equal(typeof result.error.message, 'string')
})

test('a carrier failure names the method and its root cause', async () => {
  // The phone is the only place this message is ever read. Node's own text for
  // every connection-level failure is the three words "fetch failed", which
  // name neither what was being called nor why it did not work — a report of
  // one arrived from a real phone and could not be acted on at all.
  //
  // A port that was listening and is not any more, rather than a port that
  // could never listen: this is a harness that quit, which is the case someone
  // actually hits, and it refuses the connection instead of failing to parse.
  const server = createServer()
  await new Promise((resolve) => { server.listen(0, '127.0.0.1', resolve) })
  const { port } = server.address()
  await new Promise((resolve) => { server.close(resolve) })

  const client = new DshClient({ baseUrl: `http://127.0.0.1:${port}`, requestTimeoutMs: 1_000 })
  const result = await client.call('session/page', { request: { sessionId: 's1' } })

  assert.equal(result.ok, false)
  assert.match(result.error.message, /^session\/page: /u, 'the endpoint has to be in the message')
  assert.match(result.error.message, /ECONNREFUSED/u, 'the cause is what identifies the failure')
})

test('a call carries its args in the envelope dsh 0.2 wants', async () => {
  let seen
  const server = createHttpServer((request, response) => {
    let body = ''
    request.on('data', (chunk) => { body += String(chunk) })
    request.on('end', () => {
      seen = { url: request.url, body: JSON.parse(body) }
      response.setHeader('content-type', 'application/json')
      response.end(JSON.stringify({ type: 'server-response', rpcId: seen.body.rpcId, result: { ok: true, value: 7 } }))
    })
  })
  await new Promise((resolve) => { server.listen(0, '127.0.0.1', resolve) })
  const client = new DshClient({ baseUrl: `http://127.0.0.1:${server.address().port}` })
  const result = await client.call('session/rename', { sessionId: 's1', title: 'x' })
  server.close()
  assert.deepEqual(result, { ok: true, value: 7 })
  assert.equal(seen.url, '/api/session/rename')
  assert.equal(seen.body.type, 'client-request')
  assert.equal(seen.body.method, 'session/rename', 'dsh refuses a call whose method and URL disagree')
  assert.deepEqual(seen.body.payload, { args: { sessionId: 's1', title: 'x' } })
})
