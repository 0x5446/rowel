/**
 * What only a real model can provoke, against a real dsh 0.2.
 *
 * The fake harness covers the protocol's shapes; these cover dsh's behaviour
 * where the app depends on it: an approval the model asks for, answered from
 * two phones or across a reconnect; a message queued and then cut into a
 * running turn; a turn cancelled; a subagent's log read through its parent.
 *
 * They spend model turns (about six), so they run only with
 * `ROWEL_E2E_MODEL=1`, and need a provider: dsh's own DeepSeek route takes
 * `DEEPSEEK_API_KEY`; others come from a dsh 0.1 `settings.yaml` named by
 * `ROWEL_E2E_DSH_SETTINGS` (see e2e/src/dsh.ts).
 */

import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import test from 'node:test'
import { RowelPhone, dshBinary, modelAllowed, startDsh, startStack, waitFor } from '../lib/index.js'

const skip = dshBinary() === undefined
  ? 'set ROWEL_E2E_DSH_BIN to a dsh 0.2 executable'
  : modelAllowed() ? false : 'set ROWEL_E2E_MODEL=1 to spend model turns'
const TURN_MS = 180_000

/** A prompt that makes the model ask for approval: a write under read-only. */
const ASKS_FOR_APPROVAL = 'Use the bash tool to run exactly this command: touch rowel-approval-probe.txt — '
  + 'if the sandbox refuses it, retry the same command with sandbox_permissions requesting escalation. Do nothing else.'

/**
 * A throwaway dsh with a model, a Bridle in front of it, and a way to make
 * phones for it.
 */
async function machine(t) {
  const dsh = await startDsh({ model: true })
  t.after(() => dsh.stop())
  const stack = await startStack({ dshUrl: dsh.url, dshToken: dsh.token })
  t.after(() => stack.stop())
  const phone = async () => {
    const made = new RowelPhone({ bundle: stack.invite().bundle, prefer: 'direct' })
    t.after(() => { made.close() })
    const ready = await made.connect()
    return { phone: made, ready }
  }
  return { phone }
}

/** `$events` opened and ready; returns the stream and this client's id. */
async function events(phone) {
  const stream = phone.open('$events', {})
  await waitFor(() => stream.items.some(item => item.type === 'ready'), 10_000, '$events to be ready')
  return { stream, clientId: stream.items.find(item => item.type === 'ready').clientId }
}

/** A conversation, followed, optionally under a permission preset. */
async function conversation(phone, home, preset) {
  const { value: { sessionId } } = await phone.call('session/create', { request: { cwd: home } })
  if (preset !== undefined) {
    const set = await phone.call('commands/execute', { agentId: sessionId, line: `/permission ${preset}`, submittedAttachments: [] })
    assert.equal(set.value?.result?.kind, 'success', JSON.stringify(set))
  }
  const follow = phone.open('session/follow', { request: { address: { kind: 'session', sessionId }, assistantStream: true, maxMessages: 25 } })
  await waitFor(() => follow.items.length > 0, 10_000, 'the snapshot')
  return { sessionId, follow }
}

const say = (phone, sessionId, text, requestId = randomUUID()) =>
  phone.call('session/prompt', { request: { requestId, sessionId, mode: 'queue', content: [{ type: 'text', text }] } })
const eventsOf = follow => follow.items.filter(item => item.type === 'event').map(item => item.event)
const turnEnd = follow => eventsOf(follow).find(event => event.type === 'turn/end')
const asked = stream => stream.items.find(item => item.type === 'waterfall' && item.event === 'approval/request')

test('a real approval goes to every phone, the first answer wins, and the tool runs', { skip, timeout: TURN_MS * 2 }, async (t) => {
  const { phone } = await machine(t)
  const first = await phone()
  const second = await phone()
  const one = await events(first.phone)
  const two = await events(second.phone)
  const { sessionId, follow } = await conversation(first.phone, first.ready.host.home, 'read-only')

  assert.equal((await say(first.phone, sessionId, ASKS_FOR_APPROVAL)).ok, true)
  await waitFor(() => asked(one.stream) !== undefined && asked(two.stream) !== undefined, TURN_MS, 'both phones to be asked')
  const request = asked(one.stream)
  assert.equal(asked(two.stream).eventId, request.eventId, 'one request, one id, on both phones')
  assert.equal(request.agentId, sessionId)
  assert.equal(request.request.toolName, 'bash')

  assert.equal((await first.phone.answer(one.clientId, request.eventId, 'allowed-once')).ok, true)
  await waitFor(() => two.stream.items.some(item => item.type === 'cancel' && item.eventId === request.eventId), 10_000,
    'the other phone to be told it was answered')
  // Late, and from the phone that lost: accepted, and nothing changes.
  assert.equal((await second.phone.answer(two.clientId, request.eventId, 'rejected')).ok, true)

  await waitFor(() => turnEnd(follow) !== undefined, TURN_MS, 'the turn to finish')
  const decided = eventsOf(follow).find(event => event.type === 'approval/decided')
  assert.equal(decided?.data.outcome, 'allowed-once', 'the first answer is the one dsh logged')
})

test('an approval still waiting when the phone drops is asked again, under the same id', { skip, timeout: TURN_MS * 2 }, async (t) => {
  const { phone } = await machine(t)
  const before = await phone()
  const gone = await events(before.phone)
  const { sessionId } = await conversation(before.phone, before.ready.host.home, 'read-only')
  assert.equal((await say(before.phone, sessionId, ASKS_FOR_APPROVAL)).ok, true)
  await waitFor(() => asked(gone.stream) !== undefined, TURN_MS, 'the approval')
  const eventId = asked(gone.stream).eventId
  before.phone.close()

  const after = await phone()
  const again = await events(after.phone)
  await waitFor(() => asked(again.stream) !== undefined, 10_000, 'the approval to be asked again')
  assert.equal(asked(again.stream).eventId, eventId)
  assert.notEqual(again.clientId, gone.clientId, 'a new client answers as itself')

  const follow = after.phone.open('session/follow', { request: { address: { kind: 'session', sessionId }, assistantStream: true, maxMessages: 25 } })
  assert.equal((await after.phone.answer(again.clientId, eventId, 'rejected')).ok, true)
  await waitFor(() => turnEnd(follow) !== undefined, TURN_MS, 'the turn to finish')
  assert.equal(eventsOf(follow).find(event => event.type === 'approval/decided')?.data.outcome, 'rejected')
})

test('a message queued during a turn shows in inbox, steers into it, and cancel stops the turn', { skip, timeout: TURN_MS * 2 }, async (t) => {
  const { phone } = await machine(t)
  const { phone: device, ready } = await phone()
  const control = device.open('session/control', {})
  const { sessionId, follow } = await conversation(device, ready.host.home)
  const inbox = () => control.items.filter(item => item.type === 'projection' && item.sessionId === sessionId && item.key === 'inbox').at(-1)?.value

  assert.equal((await say(device, sessionId, 'Use the bash tool to run exactly: sleep 25 — then reply with the word finished.')).ok, true)
  await waitFor(() => eventsOf(follow).some(event => event.type === 'tool/call'), TURN_MS, 'the tool to start')

  assert.equal((await say(device, sessionId, 'queued words', 'queued-1')).ok, true)
  await waitFor(() => inbox()?.['next-turn']?.some(message => message.source?.rpcId === 'queued-1'), 10_000, 'the queue to list it')
  const itemId = inbox()['next-turn'][0].id

  const steered = await device.call('session/updateQueue', { request: { sessionId, itemId, action: { kind: 'steer' } } })
  assert.equal(steered.ok, true, JSON.stringify(steered))
  await waitFor(() => inbox()?.['next-step']?.some(message => message.id === itemId), 10_000, 'it to move into the running turn')

  assert.equal((await device.call('session/cancel', { request: { sessionId } })).ok, true)
  await waitFor(() => turnEnd(follow) !== undefined, 30_000, 'the turn to stop')
  assert.equal(turnEnd(follow).data.reason.kind, 'aborted')
})

test('a subagent is read through its parent, and asks nobody', { skip, timeout: TURN_MS * 2 }, async (t) => {
  const { phone } = await machine(t)
  const { phone: device, ready } = await phone()
  const asking = await events(device)
  const { sessionId, follow } = await conversation(device, ready.host.home, 'read-only')

  assert.equal((await say(device, sessionId, 'Use the subagent tool (not run_in_background) with this prompt for the child: '
    + `"${ASKS_FOR_APPROVAL} Then reply done." Do nothing else yourself.`)).ok, true)
  await waitFor(() => turnEnd(follow) !== undefined, TURN_MS, 'the parent to finish')
  assert.equal(asked(asking.stream), undefined, 'a child runs under its parent\'s delegation, which asks nobody')

  const list = await device.call('session/list', { _request: {} })
  const child = list.value.items.find(row => row.parentSessionId === sessionId && row.origin === 'subagent')
  assert.ok(child, 'the list names the child and its parent')

  const plain = device.open('session/follow', { request: { address: { kind: 'session', sessionId: child.sessionId }, assistantStream: true, maxMessages: 25 } })
  assert.equal((await plain.done).kind, 'error')
  assert.equal((await plain.done).error.code, 'session/agent-busy')

  const address = { kind: 'subagent', parentSessionId: sessionId, childSessionId: child.sessionId, mode: 'unknown' }
  const through = device.open('session/follow', { request: { address, assistantStream: true, maxMessages: 25 } })
  await waitFor(() => through.items.length > 0, 10_000, 'the child\'s snapshot')
  const records = through.items[0].records.map(record => record.event)
  assert.equal(records.find(event => event.type === 'approval/policy')?.data.policy, 'never')
  assert.ok(records.some(event => event.type === 'tool/call'), 'the child\'s own work is in its log')
})
