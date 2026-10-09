/**
 * The contract with dsh 0.2, checked against a real one on every CI run.
 *
 * Rowel stopped working on every dsh from 0.1.2 on, and nobody noticed for a
 * month, because nothing in CI ever ran a real dsh. This is the guard
 * docs/dsh-0.2-migration.md D8 asks for: the endpoints and shapes the app
 * depends on, through a real Bridle and a real tunnel, against a throwaway dsh
 * started for the purpose — and without a model. A turn that needs one fails
 * for want of credentials, which is itself the check that the request was well
 * formed: a malformed one fails earlier, as `gateway/arguments-invalid`.
 *
 * Needs `ROWEL_E2E_DSH_BIN`; CI installs a pinned dsh and sets it, and a weekly
 * job runs the same file against dsh's `@latest` and `@alpha`.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { randomUUID } from 'node:crypto'
import { RowelPhone, dshBinary, startDsh, startStack, waitFor } from '../lib/index.js'

const dsh = dshBinary() === undefined ? undefined : await startDsh()
test.after(() => dsh?.stop())
const skip = dsh === undefined ? 'set ROWEL_E2E_DSH_BIN to a dsh 0.2 executable' : false

/** One pixel, as a phone would attach a photo. */
const PNG = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=='

let stack
let phone

test.before(async () => {
  if (dsh === undefined) return
  stack = await startStack({ dshUrl: dsh.url, dshToken: dsh.token, machineName: 'Contract Mac' })
  await waitFor(() => stack.core.dshStatus.reachable, 20_000, 'the Bridle to sign in to dsh')
})
test.after(async () => {
  phone?.close()
  await stack?.stop()
})

async function connect() {
  phone?.close()
  phone = new RowelPhone({ bundle: stack.invite().bundle, prefer: 'direct', name: 'Contract iPhone' })
  return phone.connect()
}

async function newSession() {
  const created = await phone.call('session/create', { request: { cwd: dsh.home } })
  assert.equal(created.ok, true, JSON.stringify(created))
  return created.value.sessionId
}

function follow(sessionId) {
  return phone.open('session/follow', { request: { address: { kind: 'session', sessionId }, assistantStream: true, maxMessages: 25 } })
}

/** Every session event a follow has delivered, snapshot and live. */
function eventsOf(stream) {
  return stream.items.flatMap((item) => {
    if (item.type === 'snapshot') return item.records.map(record => record.event)
    if (item.type === 'event') return [item.event]
    return []
  })
}

test('the Bridle signs in, and says which dsh it reached', { skip }, async () => {
  const ready = await connect()
  assert.equal(ready.version, 2)
  assert.equal(ready.dshReachable, true)
  assert.match(ready.dsh ?? '', /^\d+\.\d+\.\d+/u, 'ready names the dsh version')
  assert.equal(typeof ready.host?.home, 'string')
})

test('reads: list, create, follow, page, workspaces, $events, commands, presets', { skip, timeout: 60_000 }, async () => {
  await connect()
  const sessionId = await newSession()

  const listed = await phone.call('session/list', { _request: {} })
  assert.equal(listed.ok, true, JSON.stringify(listed))
  assert.ok(listed.value.items.some(item => item.sessionId === sessionId), 'the new session is listed')

  const conversation = follow(sessionId)
  const workspaces = phone.open('workspace/follow', {})
  const events = phone.open('$events', {})
  await waitFor(() => conversation.items.length > 0 && workspaces.items.length > 0 && events.items.length > 0, 10_000, 'three streams')
  const snapshot = conversation.items[0]
  assert.equal(snapshot.type, 'snapshot')
  assert.equal(typeof snapshot.cursor, 'number')
  assert.ok(Array.isArray(snapshot.records))
  assert.equal(typeof snapshot.projections?.values, 'object')
  assert.equal(workspaces.items[0].type, 'baseline')
  assert.equal(events.items[0].type, 'ready')
  assert.equal(typeof events.items[0].clientId, 'string')

  const page = await phone.call('session/page', { request: { address: { kind: 'session', sessionId }, throughSeq: snapshot.cursor, maxMessages: 10 } })
  assert.equal(page.ok, true, JSON.stringify(page))
  assert.ok(Array.isArray(page.value.records))

  const commands = await phone.call('commands/list', { agentId: sessionId })
  assert.equal(commands.ok, true, JSON.stringify(commands))
  const presets = await phone.call('permissionPresets/catalog', {})
  assert.equal(presets.ok, true, JSON.stringify(presets))
  for (const stream of [conversation, workspaces, events]) stream.cancel()
})

test('writes: a slash command round trip, no model needed', { skip, timeout: 60_000 }, async () => {
  await connect()
  const sessionId = await newSession()
  const executed = await phone.call('commands/execute', { agentId: sessionId, line: '/permission read-only', submittedAttachments: [] })
  assert.equal(executed.ok, true, JSON.stringify(executed))
  const projections = await phone.call('session/projections', { request: { sessionId } })
  assert.equal(projections.ok, true, JSON.stringify(projections))
  assert.equal(projections.value.values?.permissions?.currentValue ?? projections.value.permissions?.currentValue, 'read-only',
    `the preset did not change: ${JSON.stringify(projections.value).slice(0, 300)}`)
})

test('writes: a prompt in the shape Rowel sends is accepted, and only fails for want of a model', { skip, timeout: 60_000 }, async () => {
  await connect()
  const sessionId = await newSession()
  const conversation = follow(sessionId)
  const requestId = randomUUID()
  const sent = await phone.call('session/prompt', {
    request: {
      requestId,
      sessionId,
      mode: 'queue',
      content: [{ type: 'text', text: 'contract check' }, { type: 'image', mediaType: 'image/png', data: PNG, name: 'dot.png' }],
      clientTimeZone: 'Asia/Shanghai',
    },
  })
  assert.equal(sent.ok, true, `refused as malformed? ${JSON.stringify(sent)}`)
  assert.deepEqual(sent.value, { accepted: true })

  await waitFor(() => eventsOf(conversation).some(event => event.type === 'turn/end'), 30_000, 'the turn to end')
  const message = eventsOf(conversation).find(event => event.type === 'user/message' && event.data?.source?.rpcId === requestId)
  assert.ok(message, 'the message carries its requestId, which is what makes a retry safe')
  assert.ok(message.data.content.some(part => part.type === 'image' && typeof part.attachment?.attachmentId === 'string'),
    'the photo was stored as an attachment the app can read back')
  const end = eventsOf(conversation).find(event => event.type === 'turn/end')
  assert.equal(end.data.reason.kind, 'error')
  assert.doesNotMatch(JSON.stringify(end.data.reason), /arguments-invalid|bad-request/u, 'the request itself was rejected')
  conversation.cancel()
})

test('writes: $events/result takes the shape Rowel sends, and a late answer is harmless', { skip }, async () => {
  await connect()
  const events = phone.open('$events', {})
  await waitFor(() => events.items.some(item => item.type === 'ready'), 10_000, '$events')
  const { clientId } = events.items.find(item => item.type === 'ready')
  const answered = await phone.answer(clientId, randomUUID(), 'allowed-once')
  assert.equal(answered.ok, true, `a well-formed answer to nothing should be accepted: ${JSON.stringify(answered)}`)
  const stranger = await phone.answer(randomUUID(), randomUUID(), 'allowed-once')
  assert.equal(stranger.ok, false, 'an answer from a client dsh never saw must be refused')
  events.cancel()
})

test('a message sent as the connection drops is there once after reconnecting', { skip, timeout: 60_000 }, async () => {
  await connect()
  const sessionId = await newSession()
  const requestId = randomUUID()
  const request = { requestId, sessionId, mode: 'queue', content: [{ type: 'text', text: 'sent while leaving' }] }

  // The phone sends and goes away before any answer can come back.
  phone.callAbortable('session/prompt', { request })
  phone.close()
  phone = undefined

  await connect()
  const conversation = follow(sessionId)
  await waitFor(() => conversation.items.length > 0, 10_000, 'the snapshot')
  const mine = () => eventsOf(conversation).filter(event => event.type === 'user/message' && event.data?.source?.rpcId === requestId)
  // What the app does: if the snapshot does not show the message, send it
  // again under the same requestId; dsh ignores a repeat it already has.
  await new Promise((resolve) => { setTimeout(resolve, 1_000) })
  if (mine().length === 0) {
    const again = await phone.call('session/prompt', { request })
    assert.equal(again.ok, true, JSON.stringify(again))
  }
  await waitFor(() => mine().length > 0, 20_000, 'the message to be in the conversation')
  await new Promise((resolve) => { setTimeout(resolve, 1_500) })
  assert.equal(mine().length, 1, 'a message sent once appears once')
  conversation.cancel()
})
