/**
 * Token buckets, keyed. Plain code with no Workers API in it, so it can be
 * tested without a runtime and shared by every object that rations something.
 */

/** Burst and refill for one kind of request. */
export interface BucketLimit {
  readonly capacity: number
  readonly refillPerSecond: number
}

interface Bucket {
  tokens: number
  updatedAt: number
}

/** A set of token buckets, one per key, created full on first use. */
export class TokenBuckets {
  private readonly buckets = new Map<string, Bucket>()

  /**
   * Charge one attempt to `key`.
   * @param key - which bucket; callers put the kind of request in it.
   * @param limit - that bucket's burst and refill.
   * @param now - epoch milliseconds.
   * @returns whether the attempt may proceed.
   */
  take(key: string, limit: BucketLimit, now: number = Date.now()): boolean {
    const bucket = this.buckets.get(key) ?? { tokens: limit.capacity, updatedAt: now }
    const elapsed = Math.max(0, now - bucket.updatedAt) / 1000
    bucket.tokens = Math.min(limit.capacity, bucket.tokens + elapsed * limit.refillPerSecond)
    bucket.updatedAt = now
    if (bucket.tokens < 1) {
      this.buckets.set(key, bucket)
      return false
    }
    bucket.tokens -= 1
    this.buckets.set(key, bucket)
    // A bucket back at capacity carries no information worth remembering.
    if (bucket.tokens >= limit.capacity) this.buckets.delete(key)
    return true
  }
}
