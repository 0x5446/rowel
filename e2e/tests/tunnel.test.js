/**
 * The path a real user takes, end to end, with nothing stubbed: a phone pairs,
 * dials a Relay, and drives a real dsh 0.2 through the Bridle.
 *
 * Needs `ROWEL_E2E_DSH_BIN` (a throwaway dsh is started for this file; see
 * e2e/src/dsh.ts). The one test that runs a real model turn also needs
 * `ROWEL_E2E_MODEL=1`, because it hands that dsh this shell's provider
 * credentials and spends them.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { randomUUID } from 'node:crypto'
import { RowelPhone, dshBinary, modelAllowed, startDsh, startStack, waitFor } from '../lib/index.js'

const dsh = dshBinary() === undefined ? undefined : await startDsh()
test.after(() => dsh?.stop())
const skip = dsh === undefined ? 'set ROWEL_E2E_DSH_BIN to a dsh 0.2 executable' : false
const DSH = dsh === undefined ? {} : { dshUrl: dsh.url, dshToken: dsh.token }

/** How long a real model turn may take before the test gives up. */
const MODEL_TIMEOUT_MS = 180_000

/** Every session event a follow stream has delivered, snapshot and live. */
function eventsOf(stream) {
  return stream.items.flatMap((item) => {
    if (item.type === 'snapshot') return item.records.map(record => record.event)
    if (item.type === 'event') return [item.event]
    return []
  })
}

test('a phone pairs, reaches dsh through the relay, and follows a conversation', { skip, timeout: 120_000 }, async (t) => {
  const stack = await startStack({ ...DSH, machineName: 'E2E Machine' })
  t.after(() => stack.stop())
  await stack.waitForRelay()

  const phone = new RowelPhone({ bundle: stack.invite().bundle, prefer: 'relay', name: 'E2E iPhone' })
  t.after(() => { phone.close() })

  const ready = await phone.connect()
  assert.equal(ready.machine, 'E2E Machine', 'the app learns which machine it reached')
  assert.equal(ready.dshReachable, true, 'the bridle reports its harness as up')
  assert.equal(stack.state.peers.length, 1, 'pairing recorded the device')
  assert.equal(stack.state.peers[0].name, 'E2E iPhone')

  const created = await phone.call('session/create', { request: { cwd: ready.host.home } })
  assert.equal(created.ok, true, JSON.stringify(created))
  const conversation = phone.open('session/follow', { request: { address: { kind: 'session', sessionId: created.value.sessionId }, maxMessages: 25 } })
  await waitFor(() => conversation.items.length > 0, 10_000, 'the snapshot over the relay')
  assert.equal(conversation.items[0].type, 'snapshot')
})

test('the same phone reconnects without the pairing token', { skip, timeout: 120_000 }, async (t) => {
  const stack = await startStack({ ...DSH })
  t.after(() => stack.stop())
  await stack.waitForRelay()

  const first = new RowelPhone({ bundle: stack.invite().bundle, prefer: 'relay' })
  await first.connect()
  first.close()

  // The token was spent on the first connect. A device that is already paired
  // proves itself with its key alone.
  const second = new RowelPhone({ bundle: stack.invite().bundle, keys: first.keys, pairing: false, prefer: 'relay' })
  t.after(() => { second.close() })
  await second.connect()
  const result = await second.call('session/list', { _request: {} })
  assert.equal(result.ok, true, JSON.stringify(result))
  assert.equal(stack.state.peers.length, 1, 'reconnecting did not add a second device')
})

test('after a reconnect, reopening a conversation gives a fresh snapshot of the same place', { skip, timeout: 120_000 }, async (t) => {
  // dsh has no stream resumption, and neither does the Bridle any more: a
  // phone that comes back reopens what it was showing and replaces its window
  // with the new snapshot (docs/dsh-0.2-migration.md D4).
  const stack = await startStack({ ...DSH })
  t.after(() => stack.stop())
  const bundle = stack.invite().bundle

  const phone = new RowelPhone({ bundle, prefer: 'direct' })
  const ready = await phone.connect()
  const { value: { sessionId } } = await phone.call('session/create', { request: { cwd: ready.host.home } })
  await phone.call('session/rename', { request: { sessionId, title: 'before the drop' } })
  const before = phone.open('session/follow', { request: { address: { kind: 'session', sessionId }, maxMessages: 25 } })
  await waitFor(() => before.items.length > 0, 10_000, 'the first snapshot')
  phone.close()

  const back = new RowelPhone({ bundle, keys: phone.keys, pairing: false, prefer: 'direct' })
  t.after(() => { back.close() })
  await back.connect()
  const after = back.open('session/follow', { request: { address: { kind: 'session', sessionId }, maxMessages: 25 } })
  await waitFor(() => after.items.length > 0, 10_000, 'the snapshot after reconnecting')
  assert.equal(after.items[0].type, 'snapshot')
  assert.equal(after.items[0].cursor, before.items[0].cursor, 'nothing happened in between, so it is the same place')
})

test('a real model turn streams back to the phone', { skip: skip || (modelAllowed() ? false : 'set ROWEL_E2E_MODEL=1 to spend a model turn'), timeout: MODEL_TIMEOUT_MS + 60_000 }, async (t) => {
  const withModel = await startDsh({ model: true })
  t.after(() => withModel.stop())
  const stack = await startStack({ dshUrl: withModel.url, dshToken: withModel.token })
  t.after(() => stack.stop())

  const phone = new RowelPhone({ bundle: stack.invite().bundle, prefer: 'direct' })
  t.after(() => { phone.close() })
  const ready = await phone.connect()
  const { value: { sessionId } } = await phone.call('session/create', { request: { cwd: ready.host.home } })
  const conversation = phone.open('session/follow', { request: { address: { kind: 'session', sessionId }, assistantStream: true, maxMessages: 25 } })
  await waitFor(() => conversation.items.length > 0, 10_000, 'the snapshot')

  const sent = await phone.call('session/prompt', {
    request: { requestId: randomUUID(), sessionId, mode: 'queue', content: [{ type: 'text', text: 'Reply with exactly the word: pong' }] },
  })
  assert.equal(sent.ok, true, JSON.stringify(sent))
  await waitFor(() => eventsOf(conversation).some(event => event.type === 'turn/end'), MODEL_TIMEOUT_MS, 'the model to finish')
  const end = eventsOf(conversation).find(event => event.type === 'turn/end')
  assert.notEqual(end.data.reason.kind, 'error', `the turn failed: ${JSON.stringify(end.data.reason)}`)
  const text = eventsOf(conversation)
    .filter(event => event.type === 'assistant/message')
    .flatMap(event => event.data.message.content ?? [])
    .filter(block => block.type === 'text')
    .map(block => block.text)
    .join('')
  assert.match(text.toLowerCase(), /pong/u)
  assert.ok(conversation.items.some(item => item.type === 'assistant-stream'), 'the reply streamed as it was written')
})
