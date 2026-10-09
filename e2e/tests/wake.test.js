/**
 * Being reached when the app is not running.
 *
 * The local notification only fires while the app holds a tunnel, and it
 * usually does not: iOS suspends a backgrounded app within minutes and the
 * socket dies with it. Every question the agent asks after that point lands in
 * a machine that is waiting for someone who was never told — which is the
 * failure this whole product is supposed to prevent, since being elsewhere is
 * the premise.
 *
 * So the machine reaches out. The token crosses the Noise channel like
 * everything else, the Relay is handed it only at the moment a push is sent,
 * and the push itself carries no words — the phone wakes, opens its own tunnel,
 * asks what happened, and writes the notification locally.
 *
 * What is tested here is the decision and the address: that a Bridle rings when
 * and only when nobody is listening, that it rings the right token, and that it
 * stops when told to. Whether Apple then delivers it is Apple's, and is not
 * pretended to be covered.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { FakeAgent, RowelPhone, startStack, waitFor } from '../lib/index.js'
import { RelayServer } from '@rowel/relay'

/**
 * An approval, the kind of thing worth waking someone for, asked the way dsh
 * 0.2 asks: a waterfall on `$events`.
 * @returns {string} its eventId.
 */
function approval(agent, sessionId) {
  return agent.requestApproval({ sessionId, toolName: 'Bash' })
}

const TOKEN = 'a'.repeat(64)

test('a machine with nobody attached rings the phone it was given', { timeout: 60_000 }, async (t) => {
  const agent = new FakeAgent()
  const stack = await startStack({ agent, machineName: 'Pocket Mac', noDirect: true })
  t.after(() => stack.stop())
  await stack.waitForRelay(20_000)
  await waitFor(() => agent.eventStreams > 0, 10_000, 'the Bridle to follow $events')

  // The phone attaches once, says where it can be rung, and leaves — which is
  // what a phone does: it is in a pocket a minute later.
  const phone = new RowelPhone(stack.invite())
  await phone.connect()
  phone.wake(TOKEN)
  await waitFor(() => stack.state.peers[0]?.push !== undefined, 5_000, 'the token to be stored')
  assert.equal(stack.state.peers[0].push, TOKEN)
  phone.close()
  await waitFor(() => stack.core.attached === 0, 5_000, 'the tunnel to be released')

  approval(agent, 's1')

  await waitFor(() => stack.relay.wakes.length > 0, 5_000, 'the machine to ring the phone')
  assert.deepEqual(stack.relay.wakes[0], {
    token: TOKEN,
    machine: 'Pocket Mac',
  }, 'the ring named the wrong phone, or said more than it should')
})

test('a machine somebody is watching does not ring anyone', { timeout: 60_000 }, async (t) => {
  const agent = new FakeAgent()
  const stack = await startStack({ agent, machineName: 'Watched Mac', noDirect: true })
  t.after(() => stack.stop())
  await stack.waitForRelay(20_000)
  await waitFor(() => agent.eventStreams > 0, 10_000, 'the Bridle to follow $events')

  const phone = new RowelPhone(stack.invite())
  await phone.connect()
  phone.wake(TOKEN)
  await waitFor(() => stack.state.peers[0]?.push !== undefined, 5_000, 'the token to be stored')

  // Still attached. The app will post its own notification, with the actual
  // words in it, and a push on top would be the same interruption twice.
  approval(agent, 's1')
  const seen = await new Promise((resolve) => {
    setTimeout(() => { resolve(stack.relay.wakes.length) }, 600)
  })
  assert.equal(seen, 0, 'rang a phone that was already holding the tunnel')
  phone.close()
})

test('a phone that turns notifications off stops being rung', { timeout: 60_000 }, async (t) => {
  const agent = new FakeAgent()
  const stack = await startStack({ agent, machineName: 'Quiet Mac', noDirect: true })
  t.after(() => stack.stop())
  await stack.waitForRelay(20_000)
  await waitFor(() => agent.eventStreams > 0, 10_000, 'the Bridle to follow $events')

  const phone = new RowelPhone(stack.invite())
  await phone.connect()
  phone.wake(TOKEN)
  await waitFor(() => stack.state.peers[0]?.push !== undefined, 5_000, 'the token to be stored')
  phone.wake(null)
  await waitFor(() => stack.state.peers[0]?.push === undefined, 5_000, 'the token to be withdrawn')
  phone.close()
  await waitFor(() => stack.core.attached === 0, 5_000, 'the tunnel to be released')

  approval(agent, 's1')
  const seen = await new Promise((resolve) => {
    setTimeout(() => { resolve(stack.relay.wakes.length) }, 600)
  })
  assert.equal(seen, 0, 'kept ringing a phone that asked to be left alone')
})

test('the token survives the phone reconnecting, and is not asked for again', { timeout: 60_000 }, async (t) => {
  const agent = new FakeAgent()
  const stack = await startStack({ agent, machineName: 'Returning Mac', noDirect: true })
  t.after(() => stack.stop())
  await stack.waitForRelay(20_000)
  await waitFor(() => agent.eventStreams > 0, 10_000, 'the Bridle to follow $events')

  const invitation = stack.invite()
  const first = new RowelPhone(invitation)
  await first.connect()
  first.wake(TOKEN)
  await waitFor(() => stack.state.peers[0]?.push !== undefined, 5_000, 'the token to be stored')
  first.close()

  // Same device, new tunnel — the ordinary case every time a phone comes back
  // onto Wi-Fi. Same keys and no pairing token, because the pairing already
  // happened; a token that did not survive this would mean the machine could
  // only ring a phone that had connected since the last restart.
  const again = new RowelPhone({ bundle: invitation.bundle, keys: first.keys, pairing: false, prefer: 'relay' })
  await again.connect()
  assert.equal(stack.state.peers[0].push, TOKEN)
  again.close()
  await waitFor(() => stack.core.attached === 0, 5_000, 'the tunnel to be released')

  approval(agent, 's1')
  await waitFor(() => stack.relay.wakes.length > 0, 5_000, 'the machine to ring the phone')
})

test('a request that arrives while the relay is down is rung when it comes back', { timeout: 60_000 }, async (t) => {
  // A relay this test owns, so it can be taken away and put back on the same
  // port — which is what a deploy, a restart, or a dropped uplink looks like
  // from the Bridle's side.
  const first = new RelayServer({ port: 0, host: '127.0.0.1', recordWakes: true })
  const port = await first.listen()
  const relayUrl = `http://127.0.0.1:${port}`

  const agent = new FakeAgent()
  const stack = await startStack({ agent, machineName: 'Offline Mac', noDirect: true, relayUrl })
  t.after(() => stack.stop())
  await stack.waitForRelay(20_000)
  await waitFor(() => agent.eventStreams > 0, 10_000, 'the Bridle to follow $events')

  const phone = new RowelPhone(stack.invite())
  await phone.connect()
  phone.wake(TOKEN)
  await waitFor(() => stack.state.peers[0]?.push !== undefined, 5_000, 'the token to be stored')
  phone.close()
  await waitFor(() => stack.core.attached === 0, 5_000, 'the tunnel to be released')

  // The relay goes away, and the agent stops and asks anyway. This is not a
  // rare pairing: whatever knocked the relay out is often the same thing that
  // took the phone off the network.
  await first.close()
  await waitFor(() => stack.relayClient.connectionState !== 'online', 15_000, 'the relay to go down')
  approval(agent, 's1')

  // `onWaiting` fires once and the request is deduped afterwards, so a Bridle
  // that dropped the wake here would never ring for this question at all. It
  // has to be owed, and paid when there is somewhere to pay it.
  const second = new RelayServer({ port, host: '127.0.0.1', recordWakes: true })
  await second.listen()
  t.after(() => second.close())
  await waitFor(() => stack.relayClient.connectionState === 'online', 30_000, 'the relay to come back')

  await waitFor(() => second.wakes.length > 0, 10_000, 'the owed wake to be paid')
  assert.deepEqual(second.wakes[0], { token: TOKEN, machine: 'Offline Mac' })
})

test('one phone holding two pairings is rung once, not twice', { timeout: 60_000 }, async (t) => {
  const agent = new FakeAgent()
  const stack = await startStack({ agent, machineName: 'Twice Mac', noDirect: true })
  t.after(() => stack.stop())
  await stack.waitForRelay(20_000)
  await waitFor(() => agent.eventStreams > 0, 10_000, 'the Bridle to follow $events')

  // Two pairings, one handset. This is not contrived: `bridle revoke` is
  // manual, and a phone that has been reset arrives with a fresh device
  // identity but the same APNs token, so the old peer sits there holding the
  // same address.
  for (const name of ['before the reset', 'after the reset']) {
    const phone = new RowelPhone({ ...stack.invite(), name })
    await phone.connect()
    phone.wake(TOKEN)
    phone.close()
  }
  await waitFor(() => stack.state.peers.filter(p => p.push === TOKEN).length === 2, 5_000, 'both pairings to hold it')
  await waitFor(() => stack.core.attached === 0, 5_000, 'the tunnels to be released')

  approval(agent, 's1')
  await waitFor(() => stack.relay.wakes.length > 0, 5_000, 'the machine to ring')
  await new Promise((resolve) => { setTimeout(resolve, 400) })
  assert.equal(stack.relay.wakes.length, 1, 'the same handset was buzzed once per pairing')
})

test('a question answered while the relay was down does not ring afterwards', { timeout: 60_000 }, async (t) => {
  // The other half of remembering. A Bridle that noted "somebody is owed a
  // ring" at the moment the agent stopped, and paid it when the Relay came
  // back, would buzz a phone about a question its owner had already answered
  // in the browser — and the notification would open a card that is no longer
  // there. The decision has to be re-derived, not replayed.
  const first = new RelayServer({ port: 0, host: '127.0.0.1', recordWakes: true })
  const port = await first.listen()
  const relayUrl = `http://127.0.0.1:${port}`

  const agent = new FakeAgent()
  const stack = await startStack({ agent, machineName: 'Answered Mac', noDirect: true, relayUrl })
  t.after(() => stack.stop())
  await stack.waitForRelay(20_000)
  await waitFor(() => agent.eventStreams > 0, 10_000, 'the Bridle to follow $events')

  const phone = new RowelPhone(stack.invite())
  await phone.connect()
  phone.wake(TOKEN)
  await waitFor(() => stack.state.peers[0]?.push !== undefined, 5_000, 'the token to be stored')
  phone.close()
  await waitFor(() => stack.core.attached === 0, 5_000, 'the tunnel to be released')

  await first.close()
  await waitFor(() => stack.relayClient.connectionState !== 'online', 15_000, 'the relay to go down')

  const eventId = approval(agent, 's1')
  // Answered on the machine itself, which is what the browser two feet away is
  // for. dsh sends every holder `cancel`, and the Bridle stops holding it.
  agent.withdraw(eventId)
  await waitFor(() => stack.core.dueForRing().length === 0, 5_000, 'the request to be cleared')

  const second = new RelayServer({ port, host: '127.0.0.1', recordWakes: true })
  await second.listen()
  t.after(() => second.close())
  await waitFor(() => stack.relayClient.connectionState === 'online', 30_000, 'the relay to come back')

  await new Promise((resolve) => { setTimeout(resolve, 800) })
  assert.equal(second.wakes.length, 0, 'rang about a question that was already answered')
})

test('a question asked while somebody was attached rings once they leave', { timeout: 60_000 }, async (t) => {
  // Edge-triggered was wrong in this direction too. Asking while the phone is
  // in your hand meant no ring was ever owed — so putting the phone down
  // without answering left the machine waiting silently, forever.
  const agent = new FakeAgent()
  const stack = await startStack({ agent, machineName: 'Watched Then Away', noDirect: true })
  t.after(() => stack.stop())
  await stack.waitForRelay(20_000)
  await waitFor(() => agent.eventStreams > 0, 10_000, 'the Bridle to follow $events')

  const phone = new RowelPhone(stack.invite())
  await phone.connect()
  phone.wake(TOKEN)
  await waitFor(() => stack.state.peers[0]?.push !== undefined, 5_000, 'the token to be stored')

  // Asked while they are looking at it. Nothing should ring yet.
  approval(agent, 's1')
  await new Promise((resolve) => { setTimeout(resolve, 400) })
  assert.equal(stack.relay.wakes.length, 0, 'rang a phone that was holding the tunnel')

  // They put the phone down without answering. The machine is still waiting.
  phone.close()
  await waitFor(() => stack.core.attached === 0, 5_000, 'the tunnel to be released')
  await waitFor(() => stack.relay.wakes.length > 0, 10_000, 'the machine to ring once nobody is watching')
})
