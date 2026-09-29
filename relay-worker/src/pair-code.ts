/**
 * One short code, and the pairing bundle it buys.
 *
 * Addressed by the code itself, because that is the only thing the claimer
 * knows: `GET /v1/pair/claim?code=` carries no device id (docs/protocol.md
 * §6.2), so a directory keyed by machine cannot answer it. Naming the object
 * after the code makes the lookup a single hop with no index to keep, and
 * spreads codes across the whole namespace instead of one hot object.
 *
 * Anything held here is public by construction: the Relay could read a bundle,
 * substitute a key, and try to sit in the middle. That is precisely why the
 * bundle carries a token that only earns a request to pair, which a person at
 * the Mac accepts after comparing key fingerprints. Holding the
 * bundle is a convenience for people who cannot scan, not a trust anchor.
 */

import { DurableObject } from 'cloudflare:workers'
import type { Env } from './env.ts'

/** A bundle waiting to be claimed. */
interface HeldOffer {
  /** The machine that published it, so the Exchange can be given its slot back. */
  device: string
  /**
   * The pairing bundle as JSON text.
   *
   * Text rather than an object, so that the bundle is stored, moved between
   * objects, and returned to the phone without this code ever having a reason
   * to look inside it — the same property the tunnel has, applied to the one
   * payload the Relay does hold.
   */
  bundle: string
  expiresAt: number
}

/** What a claim yields. */
export interface Claim {
  ok: boolean
  /** The publishing machine; present only when `ok`. */
  device: string
  /** The bundle as JSON text; present only when `ok`. */
  bundle: string
}

/** A claimable pairing bundle. */
export class PairCode extends DurableObject<Env> {
  /**
   * Hold an offer until it is claimed or expires.
   * @param device - the machine publishing it.
   * @param bundle - the pairing bundle.
   * @param expiresAt - already clamped by the caller.
   */
  async put(device: string, bundle: string, expiresAt: number): Promise<void> {
    await this.ctx.storage.put('offer', { device, bundle, expiresAt } satisfies HeldOffer)
    // Codes are minted continuously and claimed rarely, so without this every
    // unclaimed code would be a row that lives forever in an object nobody
    // will ever address again.
    await this.ctx.storage.setAlarm(expiresAt)
  }

  /**
   * Claim the offer. A code works exactly once.
   * @returns the bundle, or that the code is spent, unknown, or lapsed.
   */
  async claim(): Promise<Claim> {
    const held = await this.ctx.storage.get<HeldOffer>('offer')
    // Deleted before it is returned, and in the same object that holds it, so
    // "exactly once" is a property of one storage operation rather than of two
    // requests racing.
    await this.ctx.storage.deleteAll()
    if (held === undefined || held.expiresAt <= Date.now()) return { ok: false, device: '', bundle: '' }
    return { ok: true, device: held.device, bundle: held.bundle }
  }

  /** Forget an offer nobody claimed. */
  override async alarm(): Promise<void> {
    await this.ctx.storage.deleteAll()
  }
}
