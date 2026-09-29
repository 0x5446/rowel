/**
 * The local-network listener answers anyone on the Wi-Fi before they have
 * proved anything, so what a stranger can make it hold is bounded.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { connect } from 'node:net'
import WebSocket from 'ws'
import { BridleCore, DirectServer } from '@rowel/bridle'

function core() {
  return new BridleCore(
    {
      version: 1,
      deviceId: 'd',
      privateKey: Buffer.alloc(32).toString('base64url'),
      signingKey: Buffer.alloc(64).toString('base64url'),
      machineName: 'a-mac',
      relayUrl: '',
      dshUrl: 'http://127.0.0.1:9',
      peers: [],
    },
    {
      dsh: {
        baseUrl: 'http://127.0.0.1:9',
        call: async () => ({ ok: true, value: {} }),
        health: async () => ({ reachable: false }),
        pump: async () => {},
      },
    },
  )
}

test('a stranger cannot hold more than a handful of silent sockets open', async (t) => {
  const machine = core()
  const direct = new DirectServer(machine, { version: 'test/0', port: 0 })
  const port = await direct.listen()
  const sockets = []
  t.after(() => {
    for (const socket of sockets) socket.terminate()
    direct.close()
  })
  const closes = []
  for (let i = 0; i < 9; i += 1) {
    const socket = new WebSocket(`ws://127.0.0.1:${String(port)}/v1/tunnel`)
    sockets.push(socket)
    // Turned away at the TCP connection, before any WebSocket exists: it shows
    // up here as a reset or an abnormal close, never as an open socket.
    socket.on('error', () => {})
    closes.push(new Promise((resolve) => { socket.on('close', () => { resolve('closed') }) }))
    await new Promise((resolve) => {
      socket.on('open', resolve)
      socket.on('close', resolve)
    })
  }
  const ninth = await Promise.race([closes[8], new Promise((resolve) => setTimeout(() => { resolve('still open') }, 1_000))])
  assert.equal(ninth, 'closed', 'the ninth unauthenticated socket was kept')
  const first = await Promise.race([closes[0], new Promise((resolve) => setTimeout(() => { resolve('still open') }, 100))])
  assert.equal(first, 'still open', 'the first eight should still be waiting for their handshake')
})

test('a stranger who never finishes the HTTP request is counted too', async (t) => {
  // The first version counted at the WebSocket upgrade, so connections that
  // dribbled out a request and never upgraded were not counted at all — and
  // could fill every place a phone needed.
  const machine = core()
  const direct = new DirectServer(machine, { version: 'test/0', port: 0 })
  const port = await direct.listen()
  const sockets = []
  t.after(() => {
    for (const socket of sockets) socket.destroy()
    direct.close()
  })
  const closed = []
  for (let i = 0; i < 9; i += 1) {
    const socket = connect(port, '127.0.0.1')
    socket.on('error', () => {})
    sockets.push(socket)
    closed.push(new Promise((resolve) => { socket.on('close', () => { resolve(true) }) }))
    await new Promise((resolve) => { socket.on('connect', resolve) })
    socket.write('GET /v1/tunnel HTTP/1.1\r\n')
    await new Promise((resolve) => setTimeout(resolve, 20))
  }
  const ninth = await Promise.race([closed[8], new Promise((resolve) => setTimeout(() => { resolve(false) }, 1_000))])
  assert.equal(ninth, true, 'a ninth half-open request was kept')
})
