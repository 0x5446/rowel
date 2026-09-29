/**
 * The replay buffer is what makes a phone feel like a desk.
 *
 * These tests are all about the seam between "the socket blinked" and "the user
 * noticed": a gapless resume when the buffer reaches, an honest resync when it
 * does not, and never a silently dropped frame in between.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { EventLog } from '../lib/index.js'

test('sequences start at one and never repeat', () => {
  const log = new EventLog()
  assert.equal(log.head, 0)
  assert.equal(log.append('mux', { a: 1 }).seq, 1)
  assert.equal(log.append('host', { b: 2 }).seq, 2)
  assert.equal(log.head, 2)
})

test('a phone that is fully caught up gets nothing back', () => {
  const log = new EventLog()
  log.append('mux', { a: 1 })
  const result = log.replay(1)
  assert.equal(result.kind, 'replay')
  assert.deepEqual(result.events, [])
})

test('a phone that missed frames gets exactly the gap, in order', () => {
  const log = new EventLog()
  for (let index = 0; index < 5; index += 1) log.append('mux', { index })
  const result = log.replay(2)
  assert.equal(result.kind, 'replay')
  assert.deepEqual(result.events.map(event => event.seq), [3, 4, 5])
  assert.deepEqual(result.events[0].frame, { index: 2 })
})

test('a gap wider than the buffer produces a resync instead of a lie', () => {
  const log = new EventLog(3)
  for (let index = 0; index < 10; index += 1) log.append('mux', { index })
  const result = log.replay(2)
  assert.equal(result.kind, 'resync')
  assert.equal(result.from, 10)
})

test('a phone claiming a sequence from a previous bridle is told to resync', () => {
  // The daemon restarted and its counter is back at one. Replaying nothing
  // would leave the app convinced it was up to date.
  const log = new EventLog()
  log.append('mux', { a: 1 })
  const result = log.replay(500)
  assert.equal(result.kind, 'resync')
  assert.equal(result.from, 1)
})

test('the oldest retained frame is exactly reachable', () => {
  const log = new EventLog(3)
  for (let index = 0; index < 5; index += 1) log.append('mux', { index })
  assert.equal(log.tail, 3)
  assert.equal(log.replay(2).kind, 'replay')
  assert.equal(log.replay(1).kind, 'resync')
})

test('subscribers see every frame appended after they attach', () => {
  const log = new EventLog()
  const seen = []
  const detach = log.subscribe(event => seen.push(event.seq))
  log.append('mux', {})
  log.append('mux', {})
  detach()
  log.append('mux', {})
  assert.deepEqual(seen, [1, 2])
})

test('a subscriber that throws does not stop the others', () => {
  const log = new EventLog()
  const seen = []
  log.subscribe(() => { throw new Error('broken tunnel') })
  log.subscribe(event => seen.push(event.seq))
  log.append('mux', {})
  assert.deepEqual(seen, [1])
})

test('an empty log reports a tail past its head', () => {
  const log = new EventLog()
  assert.equal(log.tail, 1)
  assert.equal(log.replay(0).kind, 'replay')
})

test('a resume counted in another process is told to refetch, even when the number fits', () => {
  // The Bridle restarted: numbering began again at 1, and this process has
  // already passed the phone's old resume point. Replaying from 500 would pass
  // the new 501.. off as a continuation and lose the new 1..500 for good.
  const previous = new EventLog()
  const current = new EventLog()
  for (let i = 0; i < 800; i += 1) current.append('mux', { i })

  assert.notEqual(previous.epoch, current.epoch)
  assert.deepEqual(current.replay(500, previous.epoch), { kind: 'resync', from: 800 })
  assert.equal(current.replay(500, current.epoch).kind, 'replay', 'the same process must still replay')
  assert.equal(current.replay(500).kind, 'replay', 'an app that sends no epoch keeps the old behaviour')
})
