/**
 * The same tunnel the app will use, against the Relay that is actually
 * deployed — not one this process started.
 *
 * Everything else in `e2e/` runs a Relay in-process on loopback. That proves
 * the protocol and proves nothing about the deployment: a tunnel that refuses
 * WebSocket upgrades, a proxy that buffers a stream into uselessness, a
 * capacity ceiling set to a number smaller than intended, TLS that only works
 * from the machine that configured it. Each of those passes every other test
 * in this directory and breaks the product.
 *
 * Skipped unless ROWEL_E2E_RELAY_URL is set, because it needs the network and
 * a Relay someone is paying for:
 *
 *   ROWEL_E2E_RELAY_URL=wss://rowel-relay.novabox.ai node --test e2e/tests/deployed.test.js
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { FakeAgent, RowelPhone, dshBinary, startDsh, startStack, waitFor } from '../lib/index.js'

const RELAY_URL = process.env.ROWEL_E2E_RELAY_URL

const skip = RELAY_URL === undefined
  ? 'no deployed relay; set ROWEL_E2E_RELAY_URL to test one'
  : false

const skipLive = skip !== false
  ? skip
  : dshBinary() === undefined ? 'set ROWEL_E2E_DSH_BIN to a dsh 0.2 executable' : false

/** A public Relay is a round trip to another continent, not a loopback hop. */
const NET_TIMEOUT_MS = 60_000

/** The same host over plain HTTPS, for the routes that are not WebSockets. */
const HTTP_BASE = RELAY_URL === undefined ? undefined : RELAY_URL.replace(/^ws/u, 'http')

/**
 * The Relay's health endpoint over plain HTTPS.
 * @returns {Promise<any>} the parsed body.
 */
async function health() {
  const url = new URL('/healthz', HTTP_BASE)
  const response = await fetch(url, { signal: AbortSignal.timeout(15_000) })
  assert.equal(response.status, 200, `GET ${url.href} should be 200`)
  return response.json()
}

/**
 * Poll an asynchronous condition. `waitFor` takes a synchronous one, and an
 * async predicate handed to it returns a always-truthy Promise — passing
 * instantly and proving nothing.
 * @param {() => Promise<boolean>} condition - checked every 500ms.
 * @param {number} timeoutMs - how long to keep trying.
 * @param {string} what - named in the timeout message.
 */
async function waitForAsync(condition, timeoutMs, what) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (await condition()) return
    await new Promise(resolve => setTimeout(resolve, 500))
  }
  throw new Error(`timed out after ${timeoutMs}ms waiting for ${what}`)
}

test('the deployed relay answers', { skip, timeout: NET_TIMEOUT_MS }, async () => {
  const body = await health()
  for (const key of ['machines', 'circuits', 'offers', 'uptimeSeconds']) {
    assert.equal(typeof body[key], 'number', `/healthz reports ${key}`)
  }
})

test('a phone pairs and drives a machine through the deployed relay', { skip, timeout: NET_TIMEOUT_MS * 3 }, async (t) => {
  // A fake agent, deliberately. This test is about the wire between here and
  // the Relay; a live model would make it slow, flaky, and about something else.
  const agent = new FakeAgent()
  const stack = await startStack({
    relayUrl: RELAY_URL,
    dshUrl: 'http://127.0.0.1:0',
    agent,
    noDirect: true,
    machineName: 'Deployed Relay Probe',
  })
  t.after(() => stack.stop())
  await stack.waitForRelay(NET_TIMEOUT_MS)

  const before = await health()
  assert.ok(before.machines >= 1, 'the bridle shows up in the relay census')

  const phone = new RowelPhone({ bundle: stack.invite().bundle, prefer: 'relay', name: 'Deploy Probe' })
  t.after(() => { phone.close() })

  const ready = await phone.connect()
  assert.equal(ready.machine, 'Deployed Relay Probe', 'the handshake completed across the public path')

  const listed = await phone.call('session/list', { _request: {} })
  assert.equal(listed.ok, true, JSON.stringify(listed))

  // Streaming, not just request/response: a proxy that buffers would pass the
  // call above and fail here.
  const events = phone.open('$events', {})
  await waitFor(() => events.items.length >= 1, NET_TIMEOUT_MS, 'the stream\'s first item to cross the tunnel')
  agent.requestApproval({ sessionId: 'probe', toolName: 'bash' })
  await waitFor(() => events.items.some(item => item.type === 'waterfall'), NET_TIMEOUT_MS, 'a pushed item to cross the tunnel')

  const during = await health()
  assert.ok(during.circuits >= 1, 'the relay is switching a circuit for this phone')
})

test('the relay forgets a phone that hangs up', { skip, timeout: NET_TIMEOUT_MS * 3 }, async (t) => {
  const stack = await startStack({
    relayUrl: RELAY_URL,
    dshUrl: 'http://127.0.0.1:0',
    agent: new FakeAgent(),
    noDirect: true,
    machineName: 'Deployed Relay Teardown',
  })
  t.after(() => stack.stop())
  await stack.waitForRelay(NET_TIMEOUT_MS)

  const phone = new RowelPhone({ bundle: stack.invite().bundle, prefer: 'relay', name: 'Hang Up' })
  await phone.connect()
  const busy = await health()
  phone.close()

  // Circuits that survive their phone are how a long-lived Relay runs out of
  // memory a month after anyone was looking at it.
  await waitForAsync(
    async () => (await health()).circuits < busy.circuits,
    NET_TIMEOUT_MS,
    'the relay to drop the circuit',
  )
})

test('a real harness is reachable through the deployed relay', { skip: skipLive, timeout: NET_TIMEOUT_MS * 4 }, async (t) => {
  const dsh = await startDsh()
  t.after(() => dsh.stop())
  const stack = await startStack({
    relayUrl: RELAY_URL,
    dshUrl: dsh.url,
    dshToken: dsh.token,
    noDirect: true,
    machineName: 'Deployed Relay Live',
  })
  t.after(() => stack.stop())
  await stack.waitForRelay(NET_TIMEOUT_MS)

  const phone = new RowelPhone({ bundle: stack.invite().bundle, prefer: 'relay', name: 'Live Probe' })
  t.after(() => { phone.close() })
  const ready = await phone.connect()
  assert.equal(ready.dshReachable, true, 'the bridle found its harness')

  const sessions = await phone.call('session/list', { _request: {} })
  assert.equal(sessions.ok, true, JSON.stringify(sessions))
  assert.ok(Array.isArray(sessions.value.items), 'the session list came back over the public path')

  // A stream, end to end through the public path: the first thing a phone
  // opens, and the thing a buffering proxy breaks.
  const workspaces = phone.open('workspace/follow', {})
  await waitFor(() => workspaces.items.some(item => item.type === 'baseline'), NET_TIMEOUT_MS, 'the workspace baseline')
})
