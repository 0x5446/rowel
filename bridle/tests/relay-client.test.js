/**
 * What redialing the Relay must never become: a hammer.
 *
 * The backoff had a hole shaped exactly like an identity fight. When two
 * Bridles hold the same key, each registration *succeeds* — and displaces the
 * other — so a reset-on-registration forgave both sides every round and the
 * pair hammered the Relay a couple of seconds apart, forever, with both
 * machines reporting themselves online the whole time. The reset has to be
 * earned by staying connected, not by getting in the door.
 *
 * The stub below plays the Relay's part in that fight: it accepts every
 * registration and then knocks the socket down, which is indistinguishable
 * from a rival Bridle displacing this one.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { WebSocketServer } from 'ws'
import { BridleCore, RelayClient } from '@rowel/bridle'

/** A core whose dsh never answers; only the relay loop is under test. */
function core(relayUrl) {
  return new BridleCore(
    {
      version: 1,
      deviceId: 'd',
      privateKey: Buffer.alloc(32).toString('base64url'),
      signingKey: Buffer.alloc(64).toString('base64url'),
      machineName: 'a-mac',
      relayUrl,
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

/**
 * A Relay that registers everyone and then displaces them.
 * @param {number[]} holds - per-connection ms to keep the socket after registering.
 * @returns the stub's url, connection count, and closer.
 */
async function displacingRelay(holds) {
  const server = new WebSocketServer({ host: '127.0.0.1', port: 0 })
  await new Promise((resolve) => server.on('listening', resolve))
  let connections = 0
  server.on('connection', (socket) => {
    const hold = holds[Math.min(connections, holds.length - 1)]
    connections += 1
    socket.send(JSON.stringify({ t: 'challenge', nonce: `n${String(connections)}` }))
    socket.on('message', (data) => {
      let message
      try {
        message = JSON.parse(String(data))
      } catch {
        return
      }
      if (message.t !== 'register') return
      socket.send(JSON.stringify({ t: 'registered', device: message.device }))
      setTimeout(() => { socket.close(4000, 'replaced by a newer connection') }, hold)
    })
  })
  return {
    url: `http://127.0.0.1:${String(server.address().port)}`,
    count: () => connections,
    close: () => new Promise((resolve) => server.close(resolve)),
  }
}

/** Poll until a condition holds. */
async function until(predicate, ms, what) {
  const started = Date.now()
  while (!predicate()) {
    if (Date.now() - started > ms) throw new Error(`timed out waiting for ${what}`)
    await new Promise((resolve) => setTimeout(resolve, 25))
  }
}

/** The seconds from every "retrying in Ns" line seen so far. */
function retriesIn(lines) {
  return lines
    .map((line) => /retrying in (\d+)s/u.exec(line))
    .filter((match) => match !== null)
    .map((match) => Number(match[1]))
}

test('being displaced is not forgiven just because registration succeeded', { timeout: 30_000 }, async (t) => {
  const relay = await displacingRelay([0])
  const machine = core(relay.url)
  await machine.start()
  const lines = []
  const client = new RelayClient(machine, { version: 'test/0', log: (line) => lines.push(line) })
  t.after(async () => {
    client.stop()
    machine.stop()
    await relay.close()
  })

  client.start()
  await until(() => retriesIn(lines).length >= 3, 20_000, 'three redials')

  // Every one of those connections registered successfully — that is the
  // fight's signature, and what separates this from a mere unreachable relay.
  assert.ok(relay.count() >= 3, 'the stub never let a registration through, so the wrong path was tested')
  const retries = retriesIn(lines)
  assert.ok(retries[2] >= 4, `the third redial waited ${String(retries[2])}s; a successful registration reset the backoff and the fight keeps its speed`)
  assert.ok(retries[0] <= retries[1] && retries[1] <= retries[2], `redial waits went ${retries.join(', ')}s; backoff is not growing`)
})

test('a connection that stays up long enough earns the floor back', { timeout: 30_000 }, async (t) => {
  // Two quick displacements to grow the backoff, then one connection that
  // survives past the stability bar. Without the reset, a laptop on flaky
  // café Wi-Fi would climb to the ceiling once and redial slowly forever.
  const relay = await displacingRelay([0, 0, 400])
  const machine = core(relay.url)
  await machine.start()
  const lines = []
  const client = new RelayClient(machine, { version: 'test/0', log: (line) => lines.push(line), stableMs: 200 })
  t.after(async () => {
    client.stop()
    machine.stop()
    await relay.close()
  })

  client.start()
  await until(() => retriesIn(lines).length >= 3, 20_000, 'three redials')

  const retries = retriesIn(lines)
  assert.ok(retries[1] >= 2, `the second redial waited ${String(retries[1])}s; the backoff never grew, so the reset below proves nothing`)
  assert.equal(retries[2], 1, `after outliving the stability bar the redial waited ${String(retries[2])}s instead of returning to the floor`)
})

/**
 * A Relay that registers everyone and then stops answering anything.
 *
 * `autoPong: false` is the whole point: the socket stays open at the TCP level
 * and the server simply never replies, which is what a Mac that changed
 * networks under a live connection looks like from this end.
 * @returns the stub's url, connection count, and closer.
 */
async function muteRelay() {
  const server = new WebSocketServer({ host: '127.0.0.1', port: 0, autoPong: false })
  await new Promise((resolve) => server.on('listening', resolve))
  let connections = 0
  server.on('connection', (socket) => {
    connections += 1
    socket.send(JSON.stringify({ t: 'challenge', nonce: `n${String(connections)}` }))
    socket.on('message', (data) => {
      let message
      try {
        message = JSON.parse(String(data))
      } catch {
        return
      }
      if (message.t !== 'register') return
      socket.send(JSON.stringify({ t: 'registered', device: message.device }))
      // And from here, nothing. No pongs, no close, no error.
    })
  })
  return {
    url: `http://127.0.0.1:${String(server.address().port)}`,
    count: () => connections,
    close: () => new Promise((resolve) => server.close(resolve)),
  }
}

test('a relay that stops answering is noticed instead of believed', { timeout: 30_000 }, async (t) => {
  // The failure this covers is silent on both ends. The Relay drops the
  // machine from its directory, every phone that dials gets 4404 "that machine
  // is offline", and this client keeps pinging a dead flow and publishing
  // `online` — so `bridle status` says the machine is up while nothing can
  // reach it, and only a restart clears it.
  const relay = await muteRelay()
  const machine = core(relay.url)
  await machine.start()
  const lines = []
  const states = []
  const client = new RelayClient(machine, {
    version: 'test/0',
    log: (line) => lines.push(line),
    onState: (state) => states.push(state),
    keepaliveMs: 100,
    silenceMs: 300,
  })
  t.after(async () => {
    client.stop()
    machine.stop()
    await relay.close()
  })

  client.start()
  await until(() => states.includes('online'), 10_000, 'the first registration')
  await until(() => relay.count() >= 2, 10_000, 'a redial after the relay went quiet')

  assert.ok(
    lines.some((line) => line.includes('went quiet')),
    `nothing reported the silence; the log said: ${lines.join(' / ')}`,
  )
  // Sampling `connectionState` here would race the redial that already
  // succeeded; what matters is that `online` was withdrawn at all.
  const first = states.indexOf('online')
  assert.ok(
    states.slice(first).includes('offline'),
    `the client never left \`online\` while the relay was not answering: ${states.join(' → ')}`,
  )
})
