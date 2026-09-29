/**
 * The local-network listener answers anyone on the Wi-Fi before they have
 * proved anything, so what a stranger can make it hold is bounded.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
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
    closes.push(new Promise((resolve) => { socket.on('close', (code) => { resolve(code) }) }))
    await new Promise((resolve) => { socket.on('open', resolve) })
  }
  const ninth = await Promise.race([closes[8], new Promise((resolve) => setTimeout(() => { resolve('still open') }, 1_000))])
  assert.equal(ninth, 1013, 'the ninth unauthenticated socket was kept')
  const first = await Promise.race([closes[0], new Promise((resolve) => setTimeout(() => { resolve('still open') }, 100))])
  assert.equal(first, 'still open', 'the first eight should still be waiting for their handshake')
})
