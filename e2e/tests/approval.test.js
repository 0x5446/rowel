/**
 * Human-in-the-loop, end to end.
 *
 * A fake harness rather than a real one, deliberately. An approval only happens
 * when a model decides to run something that needs one, and waiting for that is
 * a hope, not a test. The fake behaves like dsh 0.2's `$events` (see
 * `e2e/src/fake-agent.ts`), so everything above it — the tunnel, the stream
 * mapping, the answer's way back — is the real thing.
 *
 * The phone opens its own `$events` through the Bridle, gets its own
 * `clientId`, and answers as itself. The Bridle passes both directions through
 * and answers nothing.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { FakeAgent, RowelPhone, startStack } from '../lib/index.js'

/**
 * @param {Function} predicate - polled until it returns truthy.
 * @param {string} what - named in the timeout message.
 * @returns {Promise<void>} resolves once the predicate holds.
 */
async function waitFor(predicate, what, timeoutMs = 5_000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (predicate()) return
    await new Promise(resolve => setTimeout(resolve, 20))
  }
  throw new Error(`timed out waiting for ${what}`)
}

/**
 * A phone with `$events` open through the Bridle.
 * @param {object} t - the node:test context.
 * @param {object} [stackAndAgent] - reuse a stack and its fake.
 * @returns {Promise<object>} the phone, its events stream and clientId, and the fake.
 */
async function connected(t, stackAndAgent) {
  const agent = stackAndAgent?.agent ?? new FakeAgent()
  const stack = stackAndAgent?.stack ?? await startStack({ agent, dshUrl: 'http://127.0.0.1:3080' })
  if (stackAndAgent === undefined) t.after(() => stack.stop())

  const phone = new RowelPhone({ bundle: stack.invite().bundle, prefer: 'direct' })
  t.after(() => { phone.close() })
  await phone.connect()
  const events = phone.open('$events', {})
  await waitFor(() => events.items.some(item => item.type === 'ready'), 'the phone\'s own $events to be ready')
  const clientId = events.items.find(item => item.type === 'ready').clientId
  return { agent, stack, phone, events, clientId }
}

const waterfalls = (events, event) => events.items.filter(item => item.type === 'waterfall' && item.event === event)

test('an approval reaches the phone with everything it needs to answer', async (t) => {
  const { agent, events } = await connected(t)

  const eventId = agent.requestApproval({ sessionId: 's1', toolName: 'bash', reason: 'rm -rf /tmp/x' })

  await waitFor(() => waterfalls(events, 'approval/request').length > 0, 'the approval to arrive on the phone')
  const item = waterfalls(events, 'approval/request')[0]
  assert.equal(item.eventId, eventId, 'without the eventId the answer has nothing to address')
  assert.equal(item.agentId, 's1')
  assert.equal(item.request.toolName, 'bash')
  assert.equal(item.request.reason, 'rm -rf /tmp/x', 'the reason survives; it is what the person decides on')
})

test('the answer gets back to the harness as this phone, addressed to the right request', async (t) => {
  const { agent, phone, events, clientId } = await connected(t)

  const eventId = agent.requestApproval({ sessionId: 's1', toolName: 'bash' })
  await waitFor(() => waterfalls(events, 'approval/request').length > 0, 'the approval')

  const receipt = await phone.answer(clientId, eventId, 'allowed-once')

  assert.equal(receipt.ok, true)
  assert.deepEqual(agent.answers, [{ clientId, eventId, outcome: { kind: 'result', value: 'allowed-once' } }])
})

test('the first answer wins, and a second phone is told the question is gone', async (t) => {
  const first = await connected(t)
  const second = await connected(t, first)

  const eventId = first.agent.requestApproval({ sessionId: 's1', toolName: 'bash' })
  await waitFor(() => waterfalls(second.events, 'approval/request').length > 0, 'the approval on the second phone')

  await first.phone.answer(first.clientId, eventId, 'rejected')

  await waitFor(() => second.events.items.some(item => item.type === 'cancel' && item.eventId === eventId),
    'the second phone to hear the request was settled')
  const late = await second.phone.answer(second.clientId, eventId, 'allowed-once')
  assert.equal(late.ok, true, 'a late answer is accepted')
  assert.equal(first.agent.answers.length, 1, 'and changes nothing')
})

test('a question reaches the phone with its options intact', async (t) => {
  const { agent, events } = await connected(t)

  agent.askQuestion({ sessionId: 's1', question: 'Which branch?', options: ['main', 'develop'] })

  await waitFor(() => waterfalls(events, 'user-questions/request').length > 0, 'the question')
  const { request } = waterfalls(events, 'user-questions/request')[0]
  assert.equal(request.questions[0].question, 'Which branch?')
  assert.deepEqual(request.questions[0].options.map(o => o.label), ['main', 'develop'],
    'options that do not survive leave the person unable to answer')
})

test('an approval raised while the phone is away is waiting for it when it comes back', async (t) => {
  // The case that matters most: approvals arrive while the phone is asleep.
  // dsh re-sends every pending one to each new `$events` stream, under the
  // same id, so a phone that reconnects and reopens its stream sees it — no
  // buffer in the Bridle is needed for that, and none is kept.
  const { agent, stack, phone } = await connected(t)
  phone.close()
  const eventId = agent.requestApproval({ sessionId: 's1', toolName: 'write' })

  const again = await connected(t, { agent, stack })
  await waitFor(() => waterfalls(again.events, 'approval/request').some(item => item.eventId === eventId),
    'the pending approval to be re-sent to the reconnected phone')
})

test('an answer too big for the tunnel fails the call instead of the connection', { timeout: 120_000 }, async (t) => {
  // Every WebSocket on the path enforces a size limit by closing the
  // *connection* with a 1009, so writing an oversized frame produces a tunnel
  // that drops, reconnects, asks again and drops again — with no error
  // anywhere naming the cause.
  const agent = new FakeAgent()
  const stack = await startStack({ agent })
  t.after(() => stack.stop())
  await stack.waitForRelay()

  const phone = new RowelPhone({ bundle: stack.invite().bundle, prefer: 'relay' })
  t.after(() => { phone.close() })
  await phone.connect()

  agent.results.set('session/list', { ok: true, value: { fat: 'x'.repeat(33 * 1024 * 1024) } })
  const answer = await phone.call('session/list', { _request: {} })

  assert.equal(answer.ok, false, 'the call should fail')
  assert.equal(answer.error.code, 'too-large')
  assert.match(answer.error.message, /MB/u, 'the message should say how big it was')

  // The point of the whole exercise: the tunnel is still usable afterwards.
  agent.results.set('session/list', { ok: true, value: { items: [] } })
  const after = await phone.call('session/list', { _request: {} })
  assert.equal(after.ok, true, 'the connection survived')
})

test('a stream item too big for the tunnel ends that stream and nothing else', { timeout: 120_000 }, async (t) => {
  // A conversation's snapshot has no byte ceiling of its own — a page is
  // bounded by messages, and one message can be megabytes of streamed output.
  // The app reopens with fewer messages; the tunnel must survive to let it.
  const agent = new FakeAgent()
  agent.serve('session/follow', (args, emit) => {
    emit.item({ type: 'snapshot', pad: 'x'.repeat(33 * 1024 * 1024) })
  })
  const stack = await startStack({ agent })
  t.after(() => stack.stop())
  await stack.waitForRelay()

  const phone = new RowelPhone({ bundle: stack.invite().bundle, prefer: 'relay' })
  t.after(() => { phone.close() })
  await phone.connect()

  const follow = phone.open('session/follow', { request: { sessionId: 's1' } })
  const outcome = await follow.done
  assert.equal(outcome.kind, 'error')
  assert.equal(outcome.error.code, 'too-large')
  const after = await phone.call('session/list', { _request: {} })
  assert.equal(after.ok, true, 'the connection survived')
})
