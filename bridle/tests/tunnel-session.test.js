/**
 * One phone's tunnel, version 2: dsh's own calls and streams, passed through.
 *
 * Driven from the app's side of a real Noise handshake against a real state
 * file, with dsh replaced by the fake in `fixtures/agent.js`. What is under test
 * is what the Bridle adds on the way through — correlation, stream ownership,
 * the frame ceiling, a slow phone — and that it adds nothing else.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { BridleCore, TunnelSession, saveState } from '@rowel/bridle'
import { NoiseInitiator, TUNNEL_PROLOGUE, decodeFrame, encodeFrame, generateKeyPair } from '@rowel/protocol'
import { fakeAgent, machineState } from './fixtures/agent.js'

const appKeys = generateKeyPair()

/**
 * A handshake completed against a real state file.
 * @param {object} t - the test context.
 * @param {object} [options] - `agent` overrides, `versions` to offer, a failing `send`.
 */
async function paired(t, options = {}) {
  const home = mkdtempSync(join(tmpdir(), 'rowel-session-'))
  const previous = process.env.ROWEL_HOME
  process.env.ROWEL_HOME = home
  const fake = fakeAgent(options.agent)
  const machine = new BridleCore(machineState({ privateKey: generateKeyPair().privateKey.toString('base64url') }), { dsh: fake.agent })
  await machine.start()
  machine.state.peers.push({ key: appKeys.publicKey.toString('base64url'), name: 'a-phone', pairedAt: 0, lastSeen: 0 })
  saveState(machine.state)
  const sent = []
  let closedWhy
  let buffered = 0
  const session = new TunnelSession(machine, {
    send: options.send ?? ((bytes) => { sent.push(bytes) }),
    close: () => {},
    buffered: () => buffered,
  }, { version: 'test/0', onClosed: (why) => { closedWhy = why } })
  const initiator = new NoiseInitiator(appKeys, machine.keys.publicKey, TUNNEL_PROLOGUE)
  session.receive(initiator.writeMessage(Buffer.from(JSON.stringify({ versions: options.versions ?? [2], name: 'a-phone', client: 't' }), 'utf8')))
  t.after(() => {
    session.dispose('test over')
    machine.stop()
    if (previous === undefined) delete process.env.ROWEL_HOME
    else process.env.ROWEL_HOME = previous
    rmSync(home, { recursive: true, force: true })
  })
  const reply = sent[0] === undefined ? undefined : initiator.readMessage(sent[0])
  const decoded = []
  const channel = reply?.channel
  return {
    ...fake,
    machine,
    session,
    reply: reply === undefined ? undefined : JSON.parse(reply.payload.toString('utf8')),
    say: (frame) => { session.receive(channel.encrypt(encodeFrame(frame))) },
    // Decrypted once each and kept: the channel's counter only moves forward,
    // so a frame cannot be decrypted twice.
    frames: () => {
      while (decoded.length < sent.length - 1) decoded.push(decodeFrame(channel.decrypt(sent[decoded.length + 1])))
      return decoded
    },
    closedWhy: () => closedWhy,
    setBuffered: (bytes) => { buffered = bytes },
  }
}

const settle = () => new Promise((resolve) => { setTimeout(resolve, 20) })

test('an app that only speaks version 1 is told which version this Bridle needs', async (t) => {
  const phone = await paired(t, { versions: [1] })
  assert.equal(phone.reply.ok, false)
  assert.equal(phone.reply.reason, 'version')
  assert.deepEqual(phone.reply.supported, [2], 'the old app turns this into "update the app"; it needs the list to do so')
})

test('ready says who answers, and where the home directory is', async (t) => {
  const phone = await paired(t)
  const [ready] = phone.frames()
  assert.equal(ready.t, 'ready')
  assert.equal(ready.version, 2)
  assert.equal(typeof ready.host.home, 'string')
  assert.equal(ready.seq, undefined, 'version 2 has no event log to number')
})

test('a call goes to dsh as its endpoint and args, and its result comes back by id', async (t) => {
  const calls = []
  const phone = await paired(t, {
    agent: { call: async (endpoint, args) => { calls.push({ endpoint, args }); return { ok: true, value: { echo: args } } } },
  })
  phone.say({ t: 'call', id: 'c1', endpoint: 'session/list', args: { _request: {} } })
  await settle()
  assert.deepEqual(calls, [{ endpoint: 'session/list', args: { _request: {} } }])
  const result = phone.frames().find((frame) => frame.t === 'result')
  assert.deepEqual(result, { t: 'result', id: 'c1', result: { ok: true, value: { echo: { _request: {} } } } })
})

test('a stream is relayed item by item, and its end arrives once', async (t) => {
  const phone = await paired(t)
  phone.say({ t: 'open', sid: 'f1', endpoint: 'session/follow', args: { request: { sessionId: 's1' } } })
  const stream = phone.streams.at(-1)
  assert.equal(stream.endpoint, 'session/follow')
  assert.deepEqual(stream.args, { request: { sessionId: 's1' } })
  stream.sink.item({ type: 'snapshot' })
  stream.sink.item({ type: 'records' })
  stream.sink.end()
  stream.sink.item({ type: 'late' })
  const relayed = phone.frames().filter((frame) => frame.sid === 'f1')
  assert.deepEqual(relayed.map((frame) => frame.t), ['item', 'item', 'end'])
  assert.deepEqual(relayed[0].value, { type: 'snapshot' })
})

test('a stream error from dsh reaches the phone verbatim', async (t) => {
  const phone = await paired(t)
  phone.say({ t: 'open', sid: 'f1', endpoint: 'session/follow', args: {} })
  phone.streams.at(-1).sink.error({ code: 'gateway/arguments-invalid', message: 'missing "request"', details: { endpoint: 'session/follow' } })
  const error = phone.frames().find((frame) => frame.t === 'error')
  assert.deepEqual(error.error, { code: 'gateway/arguments-invalid', message: 'missing "request"', details: { endpoint: 'session/follow' } })
})

test('uplink items, half-close and cancel go to the stream the phone named', async (t) => {
  const phone = await paired(t)
  phone.say({ t: 'open', sid: 'a', endpoint: 'x/one', args: {} })
  phone.say({ t: 'open', sid: 'b', endpoint: 'x/two', args: {} })
  const [one, two] = phone.streams.slice(-2)
  phone.say({ t: 'item', sid: 'b', value: 42 })
  phone.say({ t: 'end', sid: 'b' })
  phone.say({ t: 'cancel', sid: 'a' })
  assert.deepEqual(two.uplink, [42])
  assert.equal(two.ended, true)
  assert.equal(one.cancelled, true)
  assert.equal(two.cancelled, false)
  one.sink.item('after cancel')
  assert.equal(phone.frames().some((frame) => frame.sid === 'a' && frame.t === 'item'), false, 'a cancelled stream kept talking')
})

test('every stream a tunnel opened is cancelled when the tunnel goes', async (t) => {
  const phone = await paired(t)
  phone.say({ t: 'open', sid: 'a', endpoint: 'x/one', args: {} })
  phone.say({ t: 'open', sid: 'b', endpoint: '$events', args: {} })
  const mine = phone.streams.slice(-2)
  phone.session.dispose('phone left')
  assert.ok(mine.every((stream) => stream.cancelled), 'a phone that left kept streams open on dsh')
})

test('the same stream id twice closes that stream, and only that stream', async (t) => {
  const phone = await paired(t)
  phone.say({ t: 'open', sid: 'a', endpoint: 'x/one', args: {} })
  phone.say({ t: 'open', sid: 'b', endpoint: 'x/other', args: {} })
  phone.say({ t: 'open', sid: 'a', endpoint: 'x/two', args: {} })
  const one = phone.streams.find((stream) => stream.endpoint === 'x/one')
  const other = phone.streams.find((stream) => stream.endpoint === 'x/other')
  const errors = phone.frames().filter((frame) => frame.t === 'error')
  assert.deepEqual(errors.map((frame) => [frame.sid, frame.error.code]), [['a', 'bad-request']])
  assert.equal(phone.streams.filter((stream) => stream.endpoint === 'x/two').length, 0)
  // To the phone an error for `a` is the end of `a`; the stream already
  // running under that id must not go on with nobody listening.
  assert.equal(one.cancelled, true)
  assert.equal(other.cancelled, false)
  one.sink.item('late')
  assert.equal(phone.frames().some((frame) => frame.sid === 'a' && frame.t === 'item'), false)
  assert.equal(phone.closedWhy(), undefined, 'dsh closes the socket for this; the Bridle must not close the tunnel')
})

test('an item too large to carry cancels its stream and says why', async (t) => {
  const phone = await paired(t)
  phone.say({ t: 'open', sid: 'big', endpoint: 'session/follow', args: {} })
  const stream = phone.streams.at(-1)
  stream.sink.item({ blob: 'x'.repeat(33 * 1024 * 1024) })
  const frames = phone.frames().filter((frame) => frame.sid === 'big')
  assert.deepEqual(frames.map((frame) => frame.t), ['error'])
  assert.equal(frames[0].error.code, 'too-large')
  assert.equal(stream.cancelled, true, 'dsh kept writing a stream nobody can receive')
  assert.equal(phone.closedWhy(), undefined, 'one oversized item took the tunnel down')
})

test('a phone that falls too far behind loses the stream, not the tunnel', async (t) => {
  const phone = await paired(t)
  phone.say({ t: 'open', sid: 'f', endpoint: 'session/follow', args: {} })
  const stream = phone.streams.at(-1)
  stream.sink.item(1)
  // The item that takes the phone over the line is written, and its stream cut.
  phone.setBuffered(9 * 1024 * 1024)
  stream.sink.item(2)
  const frames = phone.frames().filter((frame) => frame.sid === 'f')
  assert.deepEqual(frames.map((frame) => frame.t), ['item', 'item', 'error'])
  assert.equal(frames[2].error.code, 'slow-consumer')
  assert.equal(stream.cancelled, true)
})

test('a dropped connection to dsh fails the phone\'s streams so it can reopen them', async (t) => {
  const phone = await paired(t)
  phone.say({ t: 'open', sid: 'f', endpoint: 'session/follow', args: {} })
  phone.drop()
  const error = phone.frames().find((frame) => frame.t === 'error' && frame.sid === 'f')
  assert.equal(error.error.code, 'upstream-lost')
  assert.ok(phone.frames().some((frame) => frame.t === 'status' && frame.dshReachable === false))
})

test('an export too big for the tunnel is refused without reading it all into memory', async (t) => {
  let served = 0
  const phone = await paired(t, {
    agent: {
      export: async () => new Response(new ReadableStream({
        pull(controller) {
          if (served >= 40) return controller.close()
          served += 1
          controller.enqueue(new Uint8Array(1024 * 1024))
        },
      })),
    },
  })
  phone.say({ t: 'call', id: 'x1', endpoint: '$export', args: { sessionId: 's1' } })
  await new Promise((resolve) => { setTimeout(resolve, 200) })
  const answer = phone.frames().find((frame) => frame.t === 'result')
  assert.equal(answer?.result.error.code, 'too-large')
  assert.ok(served < 30, `read ${String(served)} MB of an archive it could never send`)
})

test('a second hello does not start a second ping timer', async (t) => {
  t.mock.timers.enable({ apis: ['setInterval', 'Date'] })
  const phone = await paired(t)
  phone.say({ t: 'hello' })
  phone.say({ t: 'hello' })
  t.mock.timers.tick(25_000)
  assert.equal(phone.frames().filter((frame) => frame.t === 'ping').length, 1, 'each hello left another timer running')
})

test('a phone that stops answering is let go instead of counted as listening', async (t) => {
  t.mock.timers.enable({ apis: ['setInterval', 'Date'] })
  const phone = await paired(t)
  t.mock.timers.tick(25_000)
  phone.say({ t: 'pong', nonce: '1' })
  t.mock.timers.tick(50_000)
  assert.equal(phone.closedWhy(), undefined, 'a phone answering its pings was dropped')
  t.mock.timers.tick(25_000)
  assert.equal(phone.closedWhy(), 'peer silent')
})

test('a handshake whose ready frame cannot be sent leaves nobody counted as listening', async (t) => {
  // Fails on the ready frame, not on the handshake reply: a socket that dies
  // between the two, which is what a phone walking out of range looks like.
  let sends = 0
  const phone = await paired(t, {
    send: () => {
      sends += 1
      if (sends > 1) throw new Error('socket closed')
    },
  })
  assert.equal(sends, 2, 'the handshake did not complete, so nothing below was exercised')
  assert.equal(phone.machine.attached, 0, 'a dead session is counted as a listener; push is silenced from here on')
})

test('an item that arrives while the stream is still being opened is not lost', async (t) => {
  // dsh's real socket delivers later, but nothing promises that: the
  // fake in e2e answers `$events` with its `ready` inside `open` itself, and
  // the first version of the stream table dropped exactly that item.
  const phone = await paired(t, {
    agent: {
      open: (endpoint, args, sink) => {
        sink.item({ type: 'ready', clientId: 'c1' })
        return { item: () => {}, end: () => {}, cancel: () => {} }
      },
    },
  })
  phone.say({ t: 'open', sid: 'e', endpoint: '$events', args: {} })
  const items = phone.frames().filter((frame) => frame.sid === 'e' && frame.t === 'item')
  assert.deepEqual(items.map((frame) => frame.value), [{ type: 'ready', clientId: 'c1' }])
})

test('an archive download that breaks halfway fails the call, not the process', async (t) => {
  const phone = await paired(t, {
    agent: {
      export: async () => new Response(new ReadableStream({
        pull(controller) { controller.error(new Error('socket hang up')) },
      })),
    },
  })
  phone.say({ t: 'call', id: 'x1', endpoint: '$export', args: { sessionId: 's1' } })
  await settle()
  const answer = phone.frames().find((frame) => frame.t === 'result')
  assert.equal(answer?.result.ok, false, 'an unhandled rejection here ends the process — inside dsh, with the plugin')
  assert.equal(answer.result.error.code, 'internal')
})

test('abandoning an export stops the download', async (t) => {
  let signal
  const phone = await paired(t, { agent: { export: (sessionId, descendants, given) => { signal = given; return new Promise(() => {}) } } })
  phone.say({ t: 'call', id: 'x1', endpoint: '$export', args: { sessionId: 's1' } })
  await settle()
  phone.say({ t: 'abort', id: 'x1' })
  assert.equal(signal?.aborted, true, 'the download went on after the phone gave up')
})

test('a stream error too large to send still ends the stream on the phone', async (t) => {
  const phone = await paired(t)
  phone.say({ t: 'open', sid: 'f', endpoint: 'session/follow', args: {} })
  phone.streams.at(-1).sink.error({ code: 'x', message: 'huge', details: { blob: 'y'.repeat(33 * 1024 * 1024) } })
  const ended = phone.frames().filter((frame) => frame.sid === 'f')
  assert.deepEqual(ended.map((frame) => [frame.t, frame.error?.code]), [['error', 'too-large']])
})

test('the ceiling counts what the wire adds to a frame', async (t) => {
  // A plaintext a few bytes under 32 MiB is over it once Noise's tag and the
  // Relay's header are added, and the Relay closes the whole connection for it.
  const phone = await paired(t)
  phone.say({ t: 'open', sid: 'f', endpoint: 'session/follow', args: {} })
  const envelope = JSON.stringify({ t: 'item', sid: 'f', value: '' }).length
  phone.streams.at(-1).sink.item('z'.repeat(32 * 1024 * 1024 - envelope - 10))
  const frames = phone.frames().filter((frame) => frame.sid === 'f')
  assert.deepEqual(frames.map((frame) => [frame.t, frame.error?.code]), [['error', 'too-large']])
})
