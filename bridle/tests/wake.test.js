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
 * These are the parts that decide *whether* to ring and *where* — the parts a
 * test can hold. Whether Apple then delivers it cannot be tested from here and
 * is not pretended to be.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { BridleCore, TunnelSession, saveState } from '@rowel/bridle'
import { NoiseInitiator, TUNNEL_PROLOGUE, decodeFrame, encodeFrame, generateKeyPair } from '@rowel/protocol'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

/** One phone's long-term identity, shared by the tests that need a handshake. */
const appKeys = generateKeyPair()

/** A dsh mux frame, shaped as the wire carries it. */
function frame(type, sessionId, extra = {}) {
  return {
    type: 'server-request',
    rpcId: `rpc-${type}-${sessionId}`,
    method: type,
    payload: { type, sessionId, ...extra },
  }
}

/** A core whose dsh never answers; only the bookkeeping is under test. */
function core(overrides = {}, dshExtra = {}) {
  const pumps = []
  const machine = new BridleCore(
    {
      version: 1,
      deviceId: 'd',
      privateKey: Buffer.alloc(32).toString('base64url'),
      ...overrides,
      signingKey: Buffer.alloc(64).toString('base64url'),
      machineName: 'a-mac',
      relayUrl: '',
      dshUrl: 'http://127.0.0.1:9',
      peers: [],
    },
    {
      dsh: {
        baseUrl: 'http://127.0.0.1:9',
        call: async () => ({ ok: true, value: {} }),
        health: async () => ({ reachable: false }),
        pump: async (stream, onFrame, onStatus) => { pumps.push({ stream, onFrame, onStatus }) },
        ...dshExtra,
      },
    },
  )
  return {
    machine,
    feed: (f) => { for (const p of pumps) if (p.stream === 'mux') p.onFrame(f) },
    /** The mux downlink coming back, as it does when dsh restarts. */
    reconnect: () => { for (const p of pumps) if (p.stream === 'mux') p.onStatus(true) },
    /** The mux downlink dropping. */
    disconnect: () => { for (const p of pumps) if (p.stream === 'mux') p.onStatus(false, 'gone') },
  }
}

test('a request that stops the agent says so, once', async () => {
  const { machine, feed } = core()
  await machine.start()
  let rings = 0
  machine.onWaitingChanged(() => { rings += 1 })

  feed(frame('approval/requested', 's1', { approvalId: 'a1', toolName: 'Bash' }))
  assert.equal(rings, 1)

  // dsh re-sends every pending request to each new mux subscriber, and this
  // Bridle resubscribes whenever dsh restarts. Ringing again would wake someone
  // for a question they were already woken for — possibly hours earlier.
  feed(frame('approval/requested', 's1', { approvalId: 'a1', toolName: 'Bash' }))
  assert.equal(rings, 1, 'a re-sent request rang the phone a second time')
  machine.stop()
})

test('answering says so too, because a ring owed can stop being owed', async () => {
  const { machine, feed } = core()
  await machine.start()
  feed(frame('question/requested', 's1', { questions: [{ id: 'q', question: 'which?' }] }))
  let changes = 0
  machine.onWaitingChanged(() => { changes += 1 })

  // The listener is not "somebody asked", it is "whether anyone needs fetching
  // may have changed". An answer changes it: a Bridle that noted a ring while
  // the Relay was down must not still send it once the question is settled.
  feed(frame('question/resolved', 's1'))
  assert.equal(changes, 1)
  assert.equal(machine.pendingRequests.length, 0, 'the answer did not clear the request')
  machine.stop()
})

test('an answer to something nobody asked changes nothing', async () => {
  const { machine, feed } = core()
  await machine.start()
  let changes = 0
  machine.onWaitingChanged(() => { changes += 1 })
  feed(frame('question/resolved', 's-never-asked'))
  assert.equal(changes, 0, 'a resolve for an unknown session woke the listener')
  machine.stop()
})

test('a phone arriving and leaving both change the answer', async () => {
  const { machine, feed } = core()
  await machine.start()
  feed(frame('approval/requested', 's1', { approvalId: 'a1', toolName: 'Bash' }))
  let changes = 0
  machine.onWaitingChanged(() => { changes += 1 })

  // Attaching means the person can be told on screen; detaching while the
  // request still stands is the moment a ring becomes owed. Missing the second
  // one left a machine waiting in silence after somebody put their phone down
  // without answering.
  const release = machine.attach()
  assert.equal(changes, 1, 'attaching did not re-open the question')
  release()
  assert.equal(changes, 2, 'the last phone leaving went unnoticed')
  machine.stop()
})

test('a question asked after one was answered rings again', async () => {
  const { machine, feed } = core()
  await machine.start()
  let rings = 0
  machine.onWaitingChanged(() => { rings += 1 })
  feed(frame('question/requested', 's1', { questions: [{ id: 'q', question: 'which?' }] }))
  feed(frame('question/resolved', 's1'))
  // Same session, new question. The dedupe is against a request still
  // outstanding, not against the session ever having asked one — otherwise a
  // conversation would be silent after its first question.
  feed(frame('question/requested', 's1', { questions: [{ id: 'q2', question: 'and now?' }] }))
  // Three changes: asked, answered, asked again.
  assert.equal(rings, 3)
  machine.stop()
})

test('attachments are counted, and released once however often they are dropped', async () => {
  const { machine } = core()
  await machine.start()
  assert.equal(machine.attached, 0)

  const first = machine.attach()
  const second = machine.attach()
  assert.equal(machine.attached, 2, 'two phones, one machine')

  first()
  first()
  assert.equal(machine.attached, 1, 'a session disposed twice decremented twice')

  second()
  assert.equal(machine.attached, 0)
  machine.stop()
})

test('a listener that throws does not stop the fold', async () => {
  const { machine, feed } = core()
  await machine.start()
  machine.onWaitingChanged(() => { throw new Error('the relay socket had just closed') })
  let reached = false
  machine.onWaitingChanged(() => { reached = true })

  feed(frame('approval/requested', 's1', { approvalId: 'a1', toolName: 'Edit' }))
  assert.equal(reached, true, 'one bad listener silenced the next')
  assert.equal(machine.pendingRequests.length, 1, 'the request was lost with the exception')
  machine.stop()
})

test('a new question in a session that already asked one is not mistaken for a replay', async () => {
  const { machine, feed } = core()
  await machine.start()
  let rings = 0
  machine.onWaitingChanged(() => { rings += 1 })

  feed(frame('question/requested', 's1', { questions: [{ id: 'q1', question: 'which?' }] }))
  assert.equal(rings, 1)

  // The downlink dropped and the `resolved` event was lost with it, so the old
  // request is still recorded. A genuinely new question for the same session
  // then looks exactly like the re-send dsh performs for new subscribers —
  // and keying only on the session meant nobody was rung and the phone showed
  // the stale card.
  const asked = {
    type: 'server-request',
    rpcId: 'rpc-question/requested-s1-second',
    method: 'question/requested',
    payload: { type: 'question/requested', sessionId: 's1', questions: [{ id: 'q2', question: 'and now?' }] },
  }
  feed(asked)
  assert.equal(rings, 2, 'a new question was swallowed as a replay')
  assert.deepEqual(machine.pendingRequests, [asked], 'the phone would still be shown the old question')
  machine.stop()
})

test('the same request arriving twice still rings once', async () => {
  const { machine, feed } = core()
  await machine.start()
  let rings = 0
  machine.onWaitingChanged(() => { rings += 1 })
  const asked = frame('approval/requested', 's1', { approvalId: 'a1', toolName: 'Bash' })
  feed(asked)
  feed(asked)
  feed(asked)
  assert.equal(rings, 1, 'dsh re-sending its pending list woke someone again')
  machine.stop()
})

test('a handshake whose ready frame cannot be sent leaves nobody counted as listening', async () => {
  // A real ROWEL_HOME, because the handshake re-reads the state file before
  // deciding whether this peer is paired — `bridle pair` and `bridle revoke`
  // run in other processes and have to take effect on the next handshake. An
  // in-memory peer is wiped by that re-read, which made the first version of
  // this test refuse the handshake and pass without exercising anything.
  const home = mkdtempSync(join(tmpdir(), 'rowel-wake-'))
  const previous = process.env.ROWEL_HOME
  process.env.ROWEL_HOME = home
  // A real key pair, not the all-zero one the other tests use: those never
  // reach the cryptography, and an all-zero X25519 scalar cannot complete a
  // handshake.
  const { machine } = core({ privateKey: generateKeyPair().privateKey.toString('base64url') })
  await machine.start()
  machine.state.peers.push({
    key: appKeys.publicKey.toString('base64url'),
    name: 'a-phone',
    pairedAt: 0,
    lastSeen: 0,
  })
  saveState(machine.state)

  // Fails on the ready frame, not on the handshake reply. That is the shape of
  // the real failure: a socket that dies in the millisecond between the two,
  // which is what a phone walking out of range mid-handshake looks like.
  let sends = 0
  let closedWhy
  const session = new TunnelSession(machine, {
    send: () => {
      sends += 1
      if (sends > 1) throw new Error('socket closed')
    },
    close: () => {},
  }, { version: 'test/0', onClosed: (why) => { closedWhy = why } })

  const initiator = new NoiseInitiator(appKeys, machine.keys.publicKey, TUNNEL_PROLOGUE)
  const hello = initiator.writeMessage(Buffer.from(JSON.stringify({ versions: [1], name: 'a-phone', client: 't' }), 'utf8'))
  session.receive(hello)

  // Guards the test itself. Without this it passes for the wrong reason: a
  // refused handshake never reaches the code under test, and never counts an
  // attachment either.
  assert.equal(sends, 2, `the handshake did not complete (${String(closedWhy)}), so nothing below was exercised`)

  // The count has to be back to zero. It used to be taken at the *end* of the
  // handshake, after the ready frame — and `sendFrame` swallows a transport
  // failure by disposing the session and returning normally, so the rest of the
  // handshake ran anyway and took an attachment nothing could release. The
  // machine then believed a phone was listening forever, and every wake from
  // that moment on was suppressed.
  assert.equal(machine.attached, 0, 'a dead session is counted as a listener; push is silenced from here on')
  machine.stop()
  if (previous === undefined) delete process.env.ROWEL_HOME
  else process.env.ROWEL_HOME = previous
})

test('a request dsh re-sends after its downlink comes back is still one request', async (t) => {
  t.mock.timers.enable({ apis: ['setTimeout'] })
  const { machine, feed, reconnect } = core()
  await machine.start()
  let changes = 0
  machine.onWaitingChanged(() => { changes += 1 })
  const asked = frame('approval/requested', 's1', { approvalId: 'a1', toolName: 'Bash' })
  feed(asked)
  machine.markRung()

  reconnect()
  feed(asked)
  t.mock.timers.tick(5_000)

  assert.equal(changes, 1, 'the re-send was taken for a new request')
  assert.equal(machine.pendingRequests.length, 1)
  assert.equal(machine.dueForRing().length, 0, 'the phone would be rung again for the same question')
  machine.stop()
})

test('a request dsh does not re-send after a restart is dropped, and attached phones are told', async (t) => {
  t.mock.timers.enable({ apis: ['setTimeout'] })
  const { machine, feed, reconnect } = core()
  await machine.start()
  feed(frame('question/requested', 's2', { id: 'q1' }))
  const told = []
  const unsubscribe = machine.events.subscribe((event) => { told.push(event.frame) })

  // dsh restarted: the question died with it, and nothing says "resolved".
  reconnect()
  t.mock.timers.tick(5_000)

  assert.equal(machine.pendingRequests.length, 0, 'a question nobody can answer is still offered')
  assert.deepEqual(told, [{ payload: { type: 'question/resolved', sessionId: 's2' } }])
  unsubscribe()
  machine.stop()
})

/**
 * A handshake completed against a real state file, and the pieces a test needs
 * to keep talking: the session, what it sent, and the app's end of the channel.
 */
async function pairedSession(t, dshExtra = {}) {
  const home = mkdtempSync(join(tmpdir(), 'rowel-wake-'))
  const previous = process.env.ROWEL_HOME
  process.env.ROWEL_HOME = home
  const { machine } = core({ privateKey: generateKeyPair().privateKey.toString('base64url') }, dshExtra)
  await machine.start()
  machine.state.peers.push({ key: appKeys.publicKey.toString('base64url'), name: 'a-phone', pairedAt: 0, lastSeen: 0 })
  saveState(machine.state)
  const sent = []
  let closedWhy
  const session = new TunnelSession(machine, {
    send: (bytes) => { sent.push(bytes) },
    close: () => {},
  }, { version: 'test/0', onClosed: (why) => { closedWhy = why } })
  const initiator = new NoiseInitiator(appKeys, machine.keys.publicKey, TUNNEL_PROLOGUE)
  session.receive(initiator.writeMessage(Buffer.from(JSON.stringify({ versions: [1], name: 'a-phone', client: 't' }), 'utf8')))
  const { channel } = initiator.readMessage(sent[0])
  t.after(() => {
    session.dispose('test over')
    machine.stop()
    if (previous === undefined) delete process.env.ROWEL_HOME
    else process.env.ROWEL_HOME = previous
  })
  return {
    session,
    sent,
    say: (frame) => { session.receive(channel.encrypt(encodeFrame(frame))) },
    machine,
    frames: () => sent.slice(1).map((bytes) => decodeFrame(channel.decrypt(bytes))),
    pings: () => sent.slice(1).map((bytes) => decodeFrame(channel.decrypt(bytes))).filter((f) => f.t === 'ping').length,
    closedWhy: () => closedWhy,
  }
}

test('a second hello does not start a second ping timer', async (t) => {
  t.mock.timers.enable({ apis: ['setInterval', 'Date'] })
  const phone = await pairedSession(t)
  phone.say({ t: 'hello' })
  phone.say({ t: 'hello' })
  t.mock.timers.tick(25_000)
  assert.equal(phone.pings(), 1, 'each hello left another timer running')
})

test('a phone that stops answering is let go instead of counted as listening', async (t) => {
  t.mock.timers.enable({ apis: ['setInterval', 'Date'] })
  const phone = await pairedSession(t)
  t.mock.timers.tick(25_000)
  phone.say({ t: 'pong', nonce: '1' })
  t.mock.timers.tick(50_000)
  assert.equal(phone.closedWhy(), undefined, 'a phone answering its pings was dropped')
  t.mock.timers.tick(25_000)
  assert.equal(phone.closedWhy(), 'peer silent')
})

test('an event too large to carry is replaced by an instruction to refetch', async (t) => {
  const phone = await pairedSession(t)
  phone.say({ t: 'resume', since: 0 })
  const before = phone.sent.length
  // Past the 32 MiB tunnel ceiling. Dropping it silently left the bubble it
  // belonged to unfinished forever, and when it was the last event there was
  // no later sequence number from which the gap could even be noticed.
  phone.machine.events.append('mux', { payload: { type: 'session/event', blob: 'x'.repeat(33 * 1024 * 1024) } })
  const frames = phone.frames().slice(before - 1)
  assert.deepEqual(frames.map((f) => f.t), ['resync'])
  assert.equal(frames[0].from, phone.machine.events.head)
})

test('an export too big for the tunnel is refused without reading it all into memory', async (t) => {
  let served = 0
  const phone = await pairedSession(t, {
    // 40 MB, a megabyte at a time, and counted as it goes: the archive used to
    // be read whole, base64-encoded, and only then measured.
    export: async () => new Response(new ReadableStream({
      pull(controller) {
        if (served >= 40) return controller.close()
        served += 1
        controller.enqueue(new Uint8Array(1024 * 1024))
      },
    })),
  })
  const before = phone.sent.length
  phone.say({ t: 'req', id: 'x1', method: 'session.export', payload: { sessionId: 's1' } })
  await new Promise((resolve) => setTimeout(resolve, 200))
  const answer = phone.frames().slice(before - 1).find((f) => f.t === 'res')
  assert.equal(answer?.result.ok, false)
  assert.equal(answer?.result.error.code, 'too-large')
  assert.ok(served < 30, `read ${String(served)} MB of an archive it could never send`)
})

test('a downlink that drops again before dsh re-sends does not clear what is still pending', async (t) => {
  t.mock.timers.enable({ apis: ['setTimeout'] })
  const { machine, feed, reconnect, disconnect } = core()
  await machine.start()
  feed(frame('approval/requested', 's1', { approvalId: 'a1', toolName: 'Bash' }))
  const told = []
  const unsubscribe = machine.events.subscribe((event) => { told.push(event.frame) })

  reconnect()
  t.mock.timers.tick(500)
  disconnect()
  t.mock.timers.tick(5_000)

  assert.equal(machine.pendingRequests.length, 1, 'silence on a dead downlink was taken for dsh forgetting the request')
  assert.deepEqual(told, [], 'the phone was told a live approval had been answered')
  unsubscribe()
  machine.stop()
})
