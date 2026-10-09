/**
 * What an attacker gets. Past dsh's own door — which only processes on this
 * machine can open — every guarantee in this product is the one the tunnel
 * makes: only a paired device reaches the harness, and nothing between the
 * phone and the machine — the Relay very much included — can read or alter a
 * byte.
 *
 * These are the tests that would have to fail before this is safe to ship.
 */

import assert from 'node:assert/strict'
import { Socket, createServer } from 'node:net'
import test from 'node:test'
import WebSocket from 'ws'
import { approveClaimant, reloadState, revokePeer } from '@rowel/bridle'
import { generateKeyPair } from '@rowel/protocol'
import { HandshakeRefused, RowelPhone, dshBinary, startDsh, startStack, waitFor } from '../lib/index.js'

// A throwaway dsh 0.2 for this file, isolated from the one on this machine
// (see e2e/src/dsh.ts). Skipped without one.
const dsh = dshBinary() === undefined ? undefined : await startDsh()
test.after(() => dsh?.stop())
const skip = dsh === undefined ? 'set ROWEL_E2E_DSH_BIN to a dsh 0.2 executable' : false
const DSH = dsh === undefined ? {} : { dshUrl: dsh.url, dshToken: dsh.token }

test('a device with no pairing token is refused', { skip, timeout: 60_000 }, async (t) => {
  const stack = await startStack({ ...DSH })
  t.after(() => stack.stop())
  await stack.waitForRelay()

  const bundle = { ...stack.invite().bundle }
  const stranger = new RowelPhone({ bundle, pairing: false, prefer: 'relay', name: 'Stranger' })
  t.after(() => { stranger.close() })

  await assert.rejects(() => stranger.connect(), (error) => {
    assert.ok(error instanceof HandshakeRefused, `expected a refusal, got ${String(error)}`)
    assert.equal(error.reason, 'unpaired')
    return true
  })
  assert.equal(stack.state.peers.length, 0, 'a refused device is not remembered')
})

test('a stolen pairing token works exactly once', { skip, timeout: 60_000 }, async (t) => {
  const stack = await startStack({ ...DSH })
  t.after(() => stack.stop())
  await stack.waitForRelay()
  const bundle = stack.invite().bundle

  const owner = new RowelPhone({ bundle, prefer: 'relay', name: 'Owner iPhone' })
  t.after(() => { owner.close() })
  await owner.connect()

  // Someone photographed the QR over the owner's shoulder. The token is already
  // spent, so their device is just another unpaired stranger.
  const thief = new RowelPhone({ bundle, prefer: 'relay', name: 'Thief iPhone' })
  t.after(() => { thief.close() })
  await assert.rejects(() => thief.connect(), (error) => error.reason === 'unpaired')
  assert.equal(stack.state.peers.length, 1)
})

test('the token a Relay can read earns a request to pair, never a pairing', { skip, timeout: 60_000 }, async (t) => {
  const stack = await startStack({ ...DSH })
  t.after(() => stack.stop())
  await stack.waitForRelay()
  const invitation = stack.invite()

  // What the Relay holds for the short code, used by whoever holds it — the
  // Relay itself, in the case this exists for. It used to be the QR's token,
  // and presenting it paired the presenter outright.
  const claimer = new RowelPhone({ bundle: { ...invitation.bundle, token: invitation.codeToken }, prefer: 'relay', name: 'Claimer' })
  t.after(() => { claimer.close() })
  await assert.rejects(() => claimer.connect(), (error) => error.reason === 'pending')
  reloadState(stack.state)
  assert.equal(stack.state.peers.length, 0, 'a claim alone admitted the device')
  assert.equal(stack.state.offer?.claimant?.key, claimer.keys.publicKey.toString('base64url'))

  // A person at the Mac compared the fingerprints and said yes.
  assert.ok(approveClaimant(stack.state, claimer.keys.publicKey.toString('base64url'), invitation.code))
  await claimer.connect()
  assert.equal(stack.state.peers.length, 1)
})

test('a device believing the wrong machine key cannot complete a handshake', { skip, timeout: 60_000 }, async (t) => {
  const stack = await startStack({ ...DSH })
  t.after(() => stack.stop())
  await stack.waitForRelay()

  // This is the hostile-relay case: the Relay substitutes its own static key in
  // a bundle the phone did not scan. Noise IK encrypts the initiator's first
  // message to the key it believes, so the real Bridle simply cannot open it.
  const forged = { ...stack.invite().bundle, key: generateKeyPair().publicKey.toString('base64url') }
  const phone = new RowelPhone({ bundle: forged, prefer: 'relay', name: 'Misled iPhone' })
  t.after(() => { phone.close() })

  await assert.rejects(() => phone.connect())
  assert.equal(stack.state.peers.length, 0, 'a failed handshake never reaches the pairing list')
})

test('a revoked device cannot come back', { skip, timeout: 60_000 }, async (t) => {
  const stack = await startStack({ ...DSH })
  t.after(() => stack.stop())
  await stack.waitForRelay()
  const bundle = stack.invite().bundle

  const phone = new RowelPhone({ bundle, prefer: 'relay', name: 'Lost iPhone' })
  await phone.connect()
  phone.close()

  const removed = revokePeer(stack.state, phone.keys.publicKey.toString('base64url'))
  assert.equal(removed?.name, 'Lost iPhone')

  const returning = new RowelPhone({ bundle, keys: phone.keys, pairing: false, prefer: 'relay' })
  t.after(() => { returning.close() })
  await assert.rejects(() => returning.connect(), (error) => error.reason === 'unpaired')
})

test('the relay only ever sees ciphertext', { skip, timeout: 120_000 }, async (t) => {
  const stack = await startStack({ ...DSH, machineName: 'Watched Machine' })
  t.after(() => stack.stop())
  await stack.waitForRelay()

  // A tap on the wire between the phone and the Relay. Everything the Relay
  // could possibly see passes through here first.
  const tapped = []
  const relayPort = Number(new URL(stack.relayUrl).port)
  const tap = createServer((client) => {
    const upstream = createConnection(relayPort, client, tapped)
    client.on('error', () => { upstream.destroy() })
  })
  await new Promise(resolve => tap.listen(0, '127.0.0.1', resolve))
  t.after(() => { tap.close() })

  const bundle = { ...stack.invite().bundle, relay: `http://127.0.0.1:${String(tap.address().port)}` }
  const phone = new RowelPhone({ bundle, prefer: 'relay', name: 'Tapped iPhone' })
  t.after(() => { phone.close() })

  const ready = await phone.connect()
  assert.equal(ready.machine, 'Watched Machine', 'the tunnel still works through the tap')

  const marker = 'canary-a7f3d91c-plaintext'
  const created = await phone.call('session/create', { request: { cwd: ready.host.home } })
  assert.equal(created.ok, true, JSON.stringify(created))
  const renamed = await phone.call('session/rename', { request: { sessionId: created.value.sessionId, title: marker } })
  assert.equal(renamed.ok, true, JSON.stringify(renamed))

  await waitFor(() => tapped.length > 0, 5_000, 'traffic to reach the tap')
  const wire = Buffer.concat(tapped)
  const text = wire.toString('latin1')
  for (const secret of [marker, 'session/rename', 'session/create', 'Watched Machine', created.value.sessionId]) {
    assert.equal(text.includes(secret), false, `the relay path leaked ${JSON.stringify(secret)}`)
  }
  assert.ok(wire.length > 200, 'the tap actually captured the conversation')
})

test('a tampered frame tears the tunnel down instead of being accepted', { skip, timeout: 60_000 }, async (t) => {
  const stack = await startStack({ ...DSH })
  t.after(() => stack.stop())
  await stack.waitForRelay()
  const bundle = stack.invite().bundle

  const phone = new RowelPhone({ bundle, prefer: 'relay', name: 'Honest iPhone' })
  t.after(() => { phone.close() })
  await phone.connect()
  assert.equal((await phone.call('session/list', { _request: {} })).ok, true)

  // An active attacker on the Relay flips one bit of a frame in flight. ChaCha20
  // -Poly1305 rejects it, and the session is disposed rather than resynchronized:
  // a channel someone is writing to is not a channel worth keeping.
  const socket = new WebSocket(`${toWs(stack.relayUrl)}/v1/app?device=${encodeURIComponent(stack.state.deviceId)}`)
  t.after(() => { socket.close() })
  await new Promise((resolve, reject) => {
    socket.once('open', resolve)
    socket.once('error', reject)
  })
  const closed = new Promise(resolve => socket.once('close', code => resolve(code)))
  socket.send(Buffer.from('this is not a noise handshake message, not even close'), { binary: true })
  assert.ok(await Promise.race([closed, timeout(10_000)]), 'the bridle closed the forged circuit')

  // The honest phone is untouched by someone else's failed attempt.
  assert.equal((await phone.call('session/list', { _request: {} })).ok, true, 'the real tunnel survived')
})

/**
 * Pipe one tapped client connection to the relay, recording both directions.
 * @param {number} port - the relay's port.
 * @param {import('node:net').Socket} client - the phone's connection.
 * @param {Buffer[]} sink - where captured bytes accumulate.
 * @returns {import('node:net').Socket} the upstream connection.
 */
function createConnection(port, client, sink) {
  const upstream = new Socket()
  upstream.connect(port, '127.0.0.1')
  client.on('data', chunk => { sink.push(chunk); upstream.write(chunk) })
  upstream.on('data', chunk => { sink.push(chunk); client.write(chunk) })
  upstream.on('error', () => { client.destroy() })
  client.on('close', () => { upstream.destroy() })
  upstream.on('close', () => { client.destroy() })
  return upstream
}

function toWs(base) {
  return base.replace(/^http/u, 'ws')
}

function timeout(ms) {
  return new Promise(resolve => { setTimeout(() => resolve(false), ms).unref() })
}

test('a client from the future is refused in a way it can act on', { skip, timeout: 60_000 }, async (t) => {
  // The property: a version mismatch must be an *authenticated answer*, not a
  // handshake failure. Before this, the version lived in the Noise prologue, so
  // a mismatch died inside the crypto with nothing sent back — the phone could
  // not tell version skew from a wrong machine key from tampering.
  const stack = await startStack({ ...DSH })
  t.after(() => stack.stop())

  const phone = new RowelPhone({
    bundle: stack.invite().bundle,
    prefer: 'direct',
    versions: [99],
  })
  t.after(() => { phone.close() })

  await assert.rejects(
    () => phone.connect(),
    (error) => {
      assert.match(String(error.message ?? error), /version/iu, 'the refusal names the reason')
      return true
    },
    'a version with no overlap must be refused, and refused legibly',
  )
})

test('an app that only speaks version 1 is refused, and told so', { skip, timeout: 60_000 }, async (t) => {
  // Version 2 is the deliberate exception to "speak N and N-1"
  // (docs/protocol.md §4.6): version 1 was dsh 0.1's API, which dsh 0.2
  // removed. An old app must get an answer it can act on — "update the app"
  // — not a tunnel that opens and then fails every call. That includes the
  // oldest clients, which send no `versions` key and mean `[1]`.
  const stack = await startStack({ ...DSH })
  t.after(() => stack.stop())

  for (const versions of [[1], []]) {
    const phone = new RowelPhone({ bundle: stack.invite().bundle, prefer: 'direct', versions })
    t.after(() => { phone.close() })
    await assert.rejects(() => phone.connect(), (error) => {
      assert.ok(error instanceof HandshakeRefused, `expected a refusal, got ${String(error)}`)
      assert.equal(error.reason, 'version')
      return true
    }, `versions ${JSON.stringify(versions)} should be refused as a version mismatch`)
  }
})

test('a client offering several versions gets the highest shared one', { skip, timeout: 60_000 }, async (t) => {
  const stack = await startStack({ ...DSH })
  t.after(() => stack.stop())

  // Offers a version this build does not have, plus one it does. The machine
  // must fall back rather than refuse.
  const phone = new RowelPhone({ bundle: stack.invite().bundle, prefer: 'direct', versions: [7, 2] })
  t.after(() => { phone.close() })

  const ready = await phone.connect()
  assert.equal(ready.version, 2)
})
