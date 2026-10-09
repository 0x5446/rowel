/**
 * The same-network path. A phone on the same Wi-Fi as the machine should not pay
 * for a trip to a Relay, and the product should keep working on a plane, in a
 * lab with no egress, or when the Relay is simply down.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { DIRECT_PATH, localAddresses } from '@rowel/bridle'
import { RowelPhone, dshBinary, startDsh, startStack } from '../lib/index.js'

// A throwaway dsh 0.2 for this file, isolated from the one on this machine
// (see e2e/src/dsh.ts). Skipped without one.
const dsh = dshBinary() === undefined ? undefined : await startDsh()
test.after(() => dsh?.stop())
const skip = dsh === undefined ? 'set ROWEL_E2E_DSH_BIN to a dsh 0.2 executable' : false
const DSH = dsh === undefined ? {} : { dshUrl: dsh.url, dshToken: dsh.token }

test('a phone on the same network works with the relay switched off', { skip, timeout: 60_000 }, async (t) => {
  const stack = await startStack({ ...DSH, machineName: 'Desk Mac' })
  t.after(() => stack.stop())
  await stack.waitForRelay()

  // Take the Relay away entirely. Nothing about the tunnel should depend on it.
  await stack.relay.close()

  const bundle = { ...stack.invite().bundle, direct: [`ws://127.0.0.1:${String(stack.direct.port)}`] }
  const phone = new RowelPhone({ bundle, prefer: 'direct', name: 'LAN iPhone' })
  t.after(() => { phone.close() })

  const ready = await phone.connect()
  assert.equal(ready.machine, 'Desk Mac')
  assert.equal(ready.dshReachable, true)
  // The frame that lets a phone follow a Mac across networks: the addresses it
  // can dial *now*, not the ones frozen into the pairing bundle.
  assert.ok(Array.isArray(ready.direct), 'ready must carry the current direct addresses')
  assert.ok(
    ready.direct.some((entry) => entry.endsWith(`:${String(stack.direct.port)}`)),
    `ready.direct ${JSON.stringify(ready.direct)} does not name the live listener`,
  )

  assert.equal(typeof ready.dsh, 'string', 'ready names the dsh version')
  const listed = await phone.call('session/list', { _request: {} })
  assert.equal(listed.ok, true, JSON.stringify(listed))
})

test('a stale LAN address costs one failed connect, not the session', { skip, timeout: 60_000 }, async (t) => {
  const stack = await startStack({ ...DSH, machineName: 'Away Mac' })
  t.after(() => stack.stop())
  await stack.waitForRelay()

  // The bundle was minted at home; the phone is now on cellular. Port 1 is
  // reserved and never listening, which is what a stale LAN address looks like.
  const bundle = { ...stack.invite().bundle, direct: ['ws://127.0.0.1:1'] }
  const phone = new RowelPhone({ bundle, name: 'Roaming iPhone' })
  t.after(() => { phone.close() })

  const ready = await phone.connect()
  assert.equal(ready.machine, 'Away Mac', 'the phone fell through to the relay')
  assert.equal((await phone.call('session/list', { _request: {} })).ok, true)
})

test('the same device is one identity on either path', { skip, timeout: 60_000 }, async (t) => {
  const stack = await startStack({ ...DSH })
  t.after(() => stack.stop())
  await stack.waitForRelay()
  const base = stack.invite().bundle

  const overRelay = new RowelPhone({ bundle: base, prefer: 'relay', name: 'Dual iPhone' })
  await overRelay.connect()
  overRelay.close()

  const overLan = new RowelPhone({
    bundle: { ...base, direct: [`ws://127.0.0.1:${String(stack.direct.port)}`] },
    keys: overRelay.keys,
    pairing: false,
    prefer: 'direct',
  })
  t.after(() => { overLan.close() })
  await overLan.connect()
  assert.equal(stack.state.peers.length, 1, 'switching carriers did not create a second device')
  assert.equal((await overLan.call('session/list', { _request: {} })).ok, true)
})

test('the direct listener is not a web server', { skip, timeout: 60_000 }, async (t) => {
  const stack = await startStack({ ...DSH })
  t.after(() => stack.stop())

  const response = await fetch(`http://127.0.0.1:${String(stack.direct.port)}/`)
  assert.equal(response.status, 426)
  assert.match(await response.text(), /websocket upgrade required/u)
})

test('the advertised LAN addresses are dialable websocket urls', { skip, timeout: 60_000 }, async (t) => {
  const stack = await startStack({ ...DSH })
  t.after(() => stack.stop())

  const advertised = stack.direct.addresses
  assert.equal(advertised.length, localAddresses().length)
  for (const address of advertised) {
    const url = new URL(`${address}${DIRECT_PATH}`)
    assert.equal(url.protocol, 'ws:')
    assert.equal(url.pathname, DIRECT_PATH)
    assert.equal(Number(url.port), stack.direct.port)
  }
})
