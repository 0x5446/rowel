/**
 * Reaching a phone that is not there.
 *
 * The app posts its own notification when the agent stops to ask something, and
 * that works exactly as long as the app is running. It is usually not: iOS
 * suspends it within minutes of the screen going dark, the tunnel dies with it,
 * and the machine sits waiting on someone who was never told. Being elsewhere
 * is what this product is for, so this is the common case rather than the edge
 * one.
 *
 * The Bridle follows dsh 0.2's `$events` for itself, only reading: an approval
 * or a question arrives as a waterfall with an `eventId`, and ends with a
 * `cancel` when anyone answers it. These are the parts that decide *whether*
 * to ring — the parts a test can hold. Whether Apple then delivers it cannot be
 * tested from here and is not pretended to be.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { BridleCore } from '@rowel/bridle'
import { ask, fakeAgent, machineState } from './fixtures/agent.js'

async function started(t) {
  const fake = fakeAgent()
  const machine = new BridleCore(machineState(), { dsh: fake.agent })
  await machine.start()
  await until(() => fake.eventStreams().length > 0, 'the Bridle to follow $events')
  t.after(() => { machine.stop() })
  return { machine, ...fake }
}

async function until(predicate, what) {
  const deadline = Date.now() + 3_000
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`)
    await new Promise((resolve) => { setTimeout(resolve, 5) })
  }
}

test('a request that stops the agent is owed one ring', async (t) => {
  const { machine, emit } = await started(t)
  let changes = 0
  machine.onWaitingChanged(() => { changes += 1 })
  emit(ask('e1'))
  assert.deepEqual(machine.dueForRing(), ['e1'])
  assert.equal(changes, 1)
  machine.markRung()
  assert.deepEqual(machine.dueForRing(), [], 'a ring is owed once per request, not once per reason to reconsider')
})

test('both kinds of question count, and nothing else does', async (t) => {
  const { machine, emit } = await started(t)
  emit(ask('q1', 'user-questions/request'))
  emit({ type: 'emit', event: 'api-session/status', args: [] })
  emit({ type: 'waterfall', event: 'something/else', eventId: 'x1', agentId: 'a', request: {} })
  assert.deepEqual(machine.dueForRing(), ['q1'])
})

test('an answer from anywhere ends it, and says so', async (t) => {
  const { machine, emit } = await started(t)
  emit(ask('e1'))
  let changes = 0
  machine.onWaitingChanged(() => { changes += 1 })
  emit({ type: 'cancel', eventId: 'e1' })
  assert.deepEqual(machine.dueForRing(), [])
  assert.equal(changes, 1, 'a ring owed while the Relay was down must not survive the answer')
  emit({ type: 'cancel', eventId: 'never-asked' })
  assert.equal(changes, 1, 'an answer to something nobody asked changed the answer')
})

test('a phone arriving and leaving both make the listener decide again', async (t) => {
  const { machine } = await started(t)
  let changes = 0
  machine.onWaitingChanged(() => { changes += 1 })
  const leave = machine.attach()
  assert.equal(machine.attached, 1)
  leave()
  leave()
  assert.equal(machine.attached, 0, 'released twice, counted twice')
  assert.equal(changes, 2)
})

test('a request dsh re-sends after the connection comes back is still the same request', async (t) => {
  const { machine, emit, drop, restore, eventStreams } = await started(t)
  emit(ask('e1'))
  machine.markRung()
  drop()
  restore()
  await until(() => eventStreams().length === 2, 'a fresh $events stream')
  // dsh re-sends what is still pending to the new stream, under the same id.
  emit({ type: 'ready', clientId: 'c2', host: { home: '/x' } })
  emit(ask('e1'))
  assert.deepEqual(machine.dueForRing(), [], 'a network blip rang the same phone twice for the same question')
})

test('a fresh stream starts the waiting list over, so an answer given meanwhile does not linger', async (t) => {
  const { machine, emit, drop, restore, eventStreams } = await started(t)
  emit(ask('e1'))
  drop()
  restore()
  await until(() => eventStreams().length === 2, 'a fresh $events stream')
  // Answered on the Mac while the Bridle was away: dsh does not re-send it.
  assert.deepEqual(machine.dueForRing(), [])
})

test('a ring for a request dsh did not re-send is forgotten once the re-send window closes', async (t) => {
  const { machine, emit, drop, restore, eventStreams } = await started(t)
  emit(ask('e1'))
  machine.markRung()
  drop()
  restore()
  await until(() => eventStreams().length === 2, 'a fresh $events stream')
  // Real time, not mocked timers: the wait above needs a real clock. The
  // window is two seconds.
  await new Promise((resolve) => { setTimeout(resolve, 2_200) })
  // The same id coming back now would be a new request as far as anyone can
  // tell; it must ring.
  emit(ask('e1'))
  assert.deepEqual(machine.dueForRing(), ['e1'])
})

test('the Bridle never answers', async (t) => {
  const calls = []
  const fake = fakeAgent({ call: async (endpoint, args) => { calls.push({ endpoint, args }); return { ok: true, value: {} } } })
  const machine = new BridleCore(machineState(), { dsh: fake.agent })
  await machine.start()
  t.after(() => { machine.stop() })
  await until(() => fake.eventStreams().length > 0, '$events')
  fake.emit({ type: 'ready', clientId: 'c1', host: { home: '/x' } })
  fake.emit(ask('e1'))
  await new Promise((resolve) => { setTimeout(resolve, 50) })
  assert.deepEqual(calls, [], 'the Bridle raced the phone for an answer')
})

test('dsh going away and coming back is reported, with the reason', async (t) => {
  const { machine, drop, restore } = await started(t)
  const seen = []
  machine.onDshStatus((status) => { seen.push(status.reachable) })
  drop()
  assert.equal(machine.dshStatus.reachable, false)
  restore()
  await until(() => machine.dshStatus.reachable, 'reachable again')
  assert.deepEqual(seen, [false, true])
})

test('a listener that throws does not stop the others', async (t) => {
  const { machine, emit } = await started(t)
  let heard = false
  machine.onWaitingChanged(() => { throw new Error('bad listener') })
  machine.onWaitingChanged(() => { heard = true })
  emit(ask('e1'))
  assert.equal(heard, true)
})
