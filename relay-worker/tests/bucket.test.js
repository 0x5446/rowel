/**
 * The Relay's rate limits, without a Workers runtime: the buckets are plain
 * code, so what they allow can be pinned where every `npm test` runs.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { TokenBuckets } from '../src/bucket.ts'
import { ATTACH_LIMIT, BRIDLE_LIMIT, CLAIM_LIMIT, WAKE_LIMIT } from '../src/limits.ts'

test('one kind of request cannot spend another kind\'s allowance from the same address', () => {
  // A Mac and a phone behind one home router share an address. A phone that
  // mistypes a short code ten times must not leave the Bridle unable to reconnect.
  const buckets = new TokenBuckets()
  const now = 1_000_000
  for (let i = 0; i < CLAIM_LIMIT.capacity; i += 1) assert.ok(buckets.take('claim:203.0.113.7', CLAIM_LIMIT, now))
  assert.equal(buckets.take('claim:203.0.113.7', CLAIM_LIMIT, now), false)
  assert.ok(buckets.take('bridle:203.0.113.7', BRIDLE_LIMIT, now), 'the claims spent the Bridle\'s bucket')
  assert.ok(buckets.take('attach:203.0.113.7', ATTACH_LIMIT, now), 'the claims spent the phone\'s bucket')
})

test('a machine gets a burst of wakes and then about one every six seconds', () => {
  const buckets = new TokenBuckets()
  const now = 1_000_000
  for (let i = 0; i < WAKE_LIMIT.capacity; i += 1) assert.ok(buckets.take('wake', WAKE_LIMIT, now))
  assert.equal(buckets.take('wake', WAKE_LIMIT, now), false, 'a flood of wakes was let through')
  assert.equal(buckets.take('wake', WAKE_LIMIT, now + 3_000), false)
  assert.ok(buckets.take('wake', WAKE_LIMIT, now + 6_500), 'a real machine\'s next question was refused')
})
