/**
 * A phone that arrives after the machine has stopped to ask.
 *
 * This is the app's whole premise in one test. The agent hits an approval
 * while you are somewhere else; you open Rowel; the card has to be there.
 *
 * With dsh 0.2 this holds without the Bridle keeping anything: dsh re-sends
 * every pending waterfall to each new `$events` stream, and a phone's stream is
 * new every time it attaches. What these check is that the pass-through keeps
 * that promise — and keeps the converse, that a question answered before the
 * phone arrives is not offered.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { FakeAgent, RowelPhone, startStack, waitFor } from '../lib/index.js'

async function attach(t, stack) {
  const phone = new RowelPhone({ bundle: stack.invite().bundle, name: 'Late iPhone' })
  t.after(() => { phone.close() })
  await phone.connect()
  const events = phone.open('$events', {})
  await waitFor(() => events.items.some(item => item.type === 'ready'), 10_000, 'the phone\'s $events')
  return events
}

test('a phone attaching after the question still gets it', { timeout: 60_000 }, async (t) => {
  const agent = new FakeAgent()
  const stack = await startStack({ agent, machineName: 'Waiting Mac' })
  t.after(() => stack.stop())
  await waitFor(() => agent.eventStreams > 0, 10_000, 'the Bridle to follow $events')

  // The machine stops and asks, with no phone attached at all.
  agent.askQuestion({ sessionId: 's1', question: 'Keep Exa as the only provider?', options: ['Keep', 'Switch'] })

  const events = await attach(t, stack)
  await waitFor(() => events.items.some(item => item.event === 'user-questions/request'), 10_000,
    'the pending question to be offered on attach')
  const asked = events.items.find(item => item.event === 'user-questions/request')
  assert.equal(asked.agentId, 's1')
  assert.equal(asked.request.questions[0].question, 'Keep Exa as the only provider?')
})

test('a question answered before the phone arrives is not offered again', { timeout: 60_000 }, async (t) => {
  const agent = new FakeAgent()
  const stack = await startStack({ agent, machineName: 'Answered Mac' })
  t.after(() => stack.stop())
  await waitFor(() => agent.eventStreams > 0, 10_000, 'the Bridle to follow $events')

  const eventId = agent.askQuestion({ sessionId: 's1', question: 'which?', options: ['a'] })
  // Answered on the Mac — or the turn was cancelled — before this phone connects.
  agent.withdraw(eventId)

  const events = await attach(t, stack)
  await new Promise(resolve => setTimeout(resolve, 500))
  assert.deepEqual(events.items.filter(item => item.type === 'waterfall'), [],
    'a settled question was offered to a phone as though it were still open')
})
