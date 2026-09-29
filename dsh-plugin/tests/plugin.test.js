/**
 * The plugin's contract with its host.
 *
 * Two properties matter and neither is about Rowel: `apply` must return without
 * waiting, because Cordis mounts plugins concurrently and a slow one holds up
 * the harness; and `dispose` must not throw, because a plugin that throws on
 * unload takes the reload down with it.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createServer } from 'node:http'
import { readRuntime } from '@rowel/bridle'
import { apply, name } from '../lib/index.js'

/** A stand-in for the Cordis context, capturing the dispose hook. */
function fakeContext() {
  const handlers = []
  return {
    on(event, handler) {
      assert.equal(event, 'dispose')
      handlers.push(handler)
    },
    dispose() {
      for (const handler of handlers) handler()
    },
    get count() {
      return handlers.length
    },
  }
}

/**
 * Keep this run's identity and state out of the developer's real ~/.rowel.
 *
 * Set once for the whole file rather than per test, and never restored. The
 * per-test version looked tidier and was wrong: `apply` leaves a heartbeat
 * running, so any test that did not dispose kept publishing — and by then the
 * variable had been put back, so it published into the real ~/.rowel. That
 * happened, with a stub's `http://127.0.0.1:9` in it, and `bridle status` on a
 * live machine reported the harness as down.
 */
process.env.ROWEL_HOME = mkdtempSync(join(tmpdir(), 'rowel-plugin-'))
// The machine-level index gets the same isolation: apply() registers the
// home it starts, and a test must not put its scratch identity on the
// developer's real map.
process.env.ROWEL_INSTANCES = join(process.env.ROWEL_HOME, 'instances-index.json')
// And a state file with the relay switched off, seeded before any test runs
// apply(): a fresh identity's default relayUrl is the production Relay, so
// every `npm test` was registering a throwaway machine there — visible as a
// third row on /healthz until the sweep collected it, and pure noise pollution
// against a live service. dsh is pointed at a dead port for the same reason.
writeFileSync(join(process.env.ROWEL_HOME, 'bridle.json'), JSON.stringify({
  version: 1,
  deviceId: 'plugin-test',
  privateKey: Buffer.alloc(32).toString('base64url'),
  signingKey: Buffer.alloc(64).toString('base64url'),
  machineName: 'plugin-test',
  relayUrl: '',
  dshUrl: 'http://127.0.0.1:9',
  peers: [],
}))

/** Kept as a no-op so each test still reads as isolating itself. */
function isolateHome() {
  return process.env.ROWEL_HOME
}

test('the plugin names itself for the harness plugin list', () => {
  assert.equal(name, 'rowel-bridle')
})

test('apply returns immediately and registers exactly one teardown', async (t) => {
  const previous = isolateHome()
  t.after(() => { if (previous === undefined) delete process.env.ROWEL_HOME; else process.env.ROWEL_HOME = previous })

  const ctx = fakeContext()
  const started = Date.now()
  // Point at a port nothing is listening on: the plugin must come up anyway and
  // report dsh as unreachable, exactly as the standalone binary does when the
  // harness has not started yet.
  apply(ctx, { dsh: 'http://127.0.0.1:9', relay: '', directPort: 0 })
  const elapsed = Date.now() - started

  assert.ok(elapsed < 500, `apply blocked for ${String(elapsed)}ms; Cordis mounts plugins concurrently`)
  assert.equal(ctx.count, 1, 'exactly one dispose handler, so a reload cannot leak a listener')

  // Let the async start settle so teardown has something real to tear down.
  await new Promise(resolve => setTimeout(resolve, 300))
  assert.doesNotThrow(() => { ctx.dispose() })
})

test('disposing twice is not an error', async (t) => {
  const previous = isolateHome()
  t.after(() => { if (previous === undefined) delete process.env.ROWEL_HOME; else process.env.ROWEL_HOME = previous })

  const ctx = fakeContext()
  apply(ctx, { dsh: 'http://127.0.0.1:9', relay: '', noDirect: true })
  await new Promise(resolve => setTimeout(resolve, 200))
  ctx.dispose()
  assert.doesNotThrow(() => { ctx.dispose() }, 'a second unload must be a no-op, not a crash')
})

test('a Bridle inside dsh still answers "bridle status"', async (t) => {
  const previous = isolateHome()
  t.after(() => { if (previous === undefined) delete process.env.ROWEL_HOME; else process.env.ROWEL_HOME = previous })

  // The gap this closes was found by installing the plugin and then running the
  // command the help page tells people to run when something is broken. It said
  // "bridle not running" while a Bridle was serving a phone, because the
  // snapshot those commands read was only ever written by the standalone
  // daemon. Three commands — status, doctor, pair — read it.
  const ctx = fakeContext()
  apply(ctx, { dsh: 'http://127.0.0.1:9', relay: '', directPort: 0 })
  await new Promise(resolve => setTimeout(resolve, 400))

  const live = readRuntime()
  assert.ok(live, 'nothing published, so `bridle status` would report no Bridle at all')
  assert.equal(live.pid, process.pid, 'the pid must be the host process, since that is the liveness check')
  assert.equal(live.dshUrl, 'http://127.0.0.1:9')

  ctx.dispose()
  assert.equal(readRuntime(), undefined, 'unloading left a snapshot claiming a Bridle that is gone')
})

test('a Bridle that cannot start does not take dsh with it', async (t) => {
  const previous = isolateHome()
  t.after(() => { if (previous === undefined) delete process.env.ROWEL_HOME; else process.env.ROWEL_HOME = previous })

  // Hold the port the plugin is told to use, the way a restart overlapping its
  // predecessor does. This crashed a running harness: EADDRINUSE surfaced as an
  // unhandled rejection out of `apply`'s fire-and-forget start, and Node treats
  // that as fatal. A guest must fail alone.
  const squatter = createServer()
  await new Promise(resolve => squatter.listen(0, '0.0.0.0', resolve))
  const port = squatter.address().port
  t.after(() => { squatter.close() })

  const failures = []
  const onUnhandled = (reason) => failures.push(reason)
  process.on('unhandledRejection', onUnhandled)
  t.after(() => { process.off('unhandledRejection', onUnhandled) })

  const ctx = fakeContext()
  // Disposed on the way out whatever happens: `apply` starts a heartbeat, and
  // a heartbeat that outlives its test is a process that never exits.
  t.after(() => { try { ctx.dispose() } catch { /* already down */ } })
  assert.doesNotThrow(() => { apply(ctx, { dsh: 'http://127.0.0.1:9', relay: '', directPort: port }) })
  await new Promise(resolve => setTimeout(resolve, 600))

  assert.deepEqual(failures, [], 'an unhandled rejection here is a dead harness')
})

test('an empty relay setting turns the Relay off, and is not written to the state file', async (t) => {
  // The documented meaning of `relay: ''` is "no Relay". It used to be read as
  // "not set", so the plugin dialled whatever the state file named — and a
  // non-empty setting was copied into that file on the next handshake.
  const path = join(process.env.ROWEL_HOME, 'bridle.json')
  const seeded = JSON.parse(readFileSync(path, 'utf8'))
  writeFileSync(path, JSON.stringify({ ...seeded, relayUrl: 'ws://127.0.0.1:9' }))
  t.after(() => { writeFileSync(path, JSON.stringify(seeded)) })

  const ctx = fakeContext()
  apply(ctx, { dsh: 'http://127.0.0.1:9', relay: '', noDirect: true })
  await new Promise(resolve => setTimeout(resolve, 300))
  const live = readRuntime()
  ctx.dispose()

  assert.equal(live?.relayUrl, '', 'the plugin is still pointed at a Relay')
  assert.equal(live?.relayState, 'offline')
  assert.equal(JSON.parse(readFileSync(path, 'utf8')).relayUrl, 'ws://127.0.0.1:9', 'a plugin setting reached the state file')
})
