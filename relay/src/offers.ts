/**
 * Short-code pairing offers the Relay holds on a machine's behalf.
 *
 * Anything here is public by construction: the Relay could read these bundles,
 * substitute a key, try to sit in the middle, or present the token itself.
 * That is why a short-code token only earns a request to pair, which a person
 * at the Mac accepts after comparing key fingerprints. Holding the
 * bundle is a convenience for people who cannot scan, not a trust anchor.
 */

import type { PairingBundle } from '@rowel/protocol'

/** A bundle waiting to be claimed. */
interface HeldOffer {
  bundle: PairingBundle
  expiresAt: number
}

/** Offers a single machine may hold at once, so a loop cannot fill memory. */
const MAX_OFFERS_PER_DEVICE = 3

/** Absolute ceiling on how long the Relay will hold an offer. */
const MAX_TTL_MS = 15 * 60 * 1000

/** In-memory store of claimable pairing bundles. */
export class OfferStore {
  private readonly byCode = new Map<string, HeldOffer>()
  private readonly byDevice = new Map<string, Set<string>>()

  /** How many offers are currently held. */
  get size(): number {
    return this.byCode.size
  }

  /**
   * Hold an offer until it is claimed or expires.
   * @param code - the short code that claims it.
   * @param device - the machine publishing it.
   * @param bundle - the pairing bundle.
   * @param expiresAt - requested expiry, clamped to {@link MAX_TTL_MS}.
   * @param now - current epoch milliseconds.
   * @returns whether the offer was accepted.
   */
  put(code: string, device: string, bundle: PairingBundle, expiresAt: number, now: number = Date.now()): boolean {
    this.sweep(now)
    const codes = this.byDevice.get(device) ?? new Set<string>()
    if (codes.size >= MAX_OFFERS_PER_DEVICE && !codes.has(code)) return false
    this.byCode.set(code, { bundle, expiresAt: Math.min(expiresAt, now + MAX_TTL_MS) })
    codes.add(code)
    this.byDevice.set(device, codes)
    return true
  }

  /**
   * Claim an offer. A code works exactly once.
   * @param code - the short code the user typed.
   * @param now - current epoch milliseconds.
   * @returns the bundle, or undefined when the code is unknown or expired.
   */
  claim(code: string, now: number = Date.now()): PairingBundle | undefined {
    this.sweep(now)
    const held = this.byCode.get(code)
    if (held === undefined) return undefined
    this.byCode.delete(code)
    this.byDevice.get(held.bundle.device)?.delete(code)
    return held.bundle
  }

  private sweep(now: number): void {
    for (const [code, held] of this.byCode) {
      if (held.expiresAt > now) continue
      this.byCode.delete(code)
      this.byDevice.get(held.bundle.device)?.delete(code)
    }
    for (const [device, codes] of this.byDevice) {
      if (codes.size === 0) this.byDevice.delete(device)
    }
  }
}
