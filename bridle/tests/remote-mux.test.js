/**
 * The one socket every stream shares, against a real WebSocket server that
 * speaks dsh's stream framing (docs/dsh-0.2-protocol.md §3).
 *
 * The rule under test is the one that keeps phones from waiting forever: when
 * the socket to dsh drops, every stream on it ends — once, with
 * `upstream-lost` — and a stream opened after the redial works.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { WebSocketServer } from 'ws'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const home = mkdtempSync(join(tmpdir(), 'rowel-mux-'))
process.env['ROWEL_HOME'] = home
test.after(() => { rmSync(home, { recursive: true, force: true }) })
const { RemoteMux } = await import('@rowel/bridle')

/** A dsh stand-in: echoes each open as one item, and records every frame. */
async function fakeStreamServer() {
  const server = new WebSocketServer({ host: '127.0.0.1', port: 0, path: '/api/remote.mux' })
  await new Promise((resolve) => { server.once('listening', resolve) })
  const frames = []
  const sockets = []
  server.on('connection', (socket) => {
    sockets.push(socket)
    socket.on('message', (data) => {
      const frame = JSON.parse(String(data))
      frames.push(frame)
      if (frame.type === 'open') socket.send(JSON.stringify({ type: 'item', streamId: frame.streamId, value: { opened: frame.endpoint } }))
    })
  })
  return {
    url: `http://127.0.0.1:${String(server.address().port)}`,
    frames,
    dropAll: () => { for (const socket of sockets.splice(0)) socket.terminate() },
    connections: () => sockets.length,
    close: () => new Promise((resolve) => { server.close(resolve) }),
  }
}

async function until(predicate, what, timeoutMs = 5_000) {
  const deadline = Date.now() + timeoutMs
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`)
    await new Promise((resolve) => { setTimeout(resolve, 10) })
  }
}

function sink() {
  const seen = { items: [], ends: 0, errors: [] }
  return { seen, sink: { item: (value) => { seen.items.push(value) }, end: () => { seen.ends += 1 }, error: (error) => { seen.errors.push(error) } } }
}

test('a dropped socket ends every stream on it once, and a stream opened after the redial works', async (t) => {
  const dsh = await fakeStreamServer()
  const mux = new RemoteMux(dsh.url)
  t.after(async () => { mux.stop(); await dsh.close() })
  mux.start()
  await until(() => mux.state.connected, 'the first connection')

  const a = sink()
  const b = sink()
  mux.open('session/follow', { request: {} }, a.sink)
  mux.open('$events', {}, b.sink)
  await until(() => a.seen.items.length === 1 && b.seen.items.length === 1, 'both streams to open')

  dsh.dropAll()
  await until(() => !mux.state.connected, 'the drop to be noticed')
  await until(() => a.seen.errors.length > 0 && b.seen.errors.length > 0, 'both streams to fail')
  assert.deepEqual(a.seen.errors.map(error => error.code), ['upstream-lost'])
  assert.deepEqual(b.seen.errors.map(error => error.code), ['upstream-lost'])

  await until(() => mux.state.connected, 'the redial', 15_000)
  const c = sink()
  mux.open('workspace/follow', {}, c.sink)
  await until(() => c.seen.items.length === 1, 'a stream on the new socket')
  assert.deepEqual(c.seen.items, [{ opened: 'workspace/follow' }])
  assert.equal(a.seen.errors.length, 1, 'a stream heard its end twice')
})

test('opening while not connected fails at once instead of queuing', async () => {
  const mux = new RemoteMux('http://127.0.0.1:1')
  const a = sink()
  mux.open('session/follow', {}, a.sink)
  await until(() => a.seen.errors.length > 0, 'the failure')
  assert.equal(a.seen.errors[0].code, 'upstream-lost')
})

test('a cancelled stream hears nothing more, and dsh is told', async (t) => {
  const dsh = await fakeStreamServer()
  const mux = new RemoteMux(dsh.url)
  t.after(async () => { mux.stop(); await dsh.close() })
  mux.start()
  await until(() => mux.state.connected, 'the connection')
  const a = sink()
  const handle = mux.open('session/follow', {}, a.sink)
  await until(() => a.seen.items.length === 1, 'the stream to open')
  handle.cancel()
  await until(() => dsh.frames.some(frame => frame.type === 'cancel'), 'dsh to hear the cancel')
  dsh.dropAll()
  await until(() => !mux.state.connected, 'the drop')
  assert.deepEqual(a.seen.errors, [], 'a cancelled stream was told it failed')
})
