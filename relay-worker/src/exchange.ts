/**
 * The one global object: which machines are online, and where.
 *
 * The Node Relay keeps this in a `Map` in the process that also holds every
 * socket, so "look up a machine" and "reach its socket" are the same act. Here
 * they cannot be: a Bridle's socket lands in a Switchboard object chosen before
 * anyone knows which machine it belongs to (the device id arrives *after* the
 * upgrade, docs/protocol.md §6.1), so the two have to be introduced. This is
 * the introducer — it maps a device id to the Switchboard holding that Bridle,
 * and nothing else knows that mapping.
 *
 * It is also the only place a global count can exist, and `/healthz` promises
 * one, so the census, the global ceilings, and the per-caller rate limits live
 * here too rather than in three more objects.
 *
 * What it stores is what `registry.ts` stores: a device id, a display name, a
 * version string, and numbers. No traffic passes through it — a phone's bytes
 * never touch this object, only its connection does.
 */

import { DurableObject } from 'cloudflare:workers'
import type { Env } from './env.ts'
import { TokenBuckets } from './bucket.ts'
import {
  ATTACH_LIMIT,
  BRIDLE_LIMIT,
  CLAIM_LIMIT,
  DEFAULT_MAX_CIRCUITS,
  DEFAULT_MAX_MACHINES,
  SWEEP_INTERVAL_MS,
  MAX_OFFERS_PER_DEVICE,
  positiveInt,
} from './limits.ts'

/** One online machine. */
interface MachineRow {
  /** `DurableObjectId.toString()` of the Switchboard holding its socket. */
  switchboard: string
  name: string
  version: string
  /** Epoch milliseconds the Bridle registered. */
  since: number
  /** Phones attached right now, mirrored from the Switchboard for `/healthz`. */
  circuits: number
}

/** What the stored rows add up to, counted fresh each time. */
interface Counts {
  machines: number
  circuits: number
  offers: number
}

/** Short codes one machine is currently holding, and when each lapses. */
type OfferSlots = Record<string, number>

/** Why an attach was refused, in the close codes docs/protocol.md §8 defines. */
export interface AttachRefusal {
  ok: false
  code: number
  reason: string
}

/** Where to send a phone. */
export interface AttachRoute {
  ok: true
  switchboard: string
}

/** What `/healthz` answers. */
export interface Health {
  machines: number
  circuits: number
  offers: number
  uptimeSeconds: number
}

/** What `GET /v1/machine/:deviceId` answers. */
export type MachineDescription = { online: false } | { online: true; name: string; version: string }

/** The directory, the census, the ceilings, and the rate limits. */
export class Exchange extends DurableObject<Env> {
  private readonly maxMachines: number
  private readonly sweepInterval: number
  private readonly maxCircuits: number
  /**
   * Rate-limit buckets, in memory on purpose.
   *
   * Losing them when this object is evicted is not a hole: eviction only
   * happens after a stretch with no traffic, and a caller who has stopped
   * calling is exactly the one whose bucket has refilled anyway. Under an
   * actual flood the object stays resident and the buckets hold.
   *
   * One bucket per kind of request (`attach:`, `claim:`, `bridle:` + address),
   * as the Node Relay keeps three limiters. A Mac and a phone behind one home
   * address share the address, and with one bucket per address a phone
   * mistyping a short code, or reconnecting in a hurry, spent the Bridle's
   * reconnects too.
   */
  private readonly buckets = new TokenBuckets()

  /** @param ctx - the object's own storage and scheduling. @param env - bindings. */
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env)
    this.maxMachines = positiveInt(env.ROWEL_MAX_MACHINES, DEFAULT_MAX_MACHINES)
    // Overridable so a test can force a sweep without waiting ten minutes.
    this.sweepInterval = positiveInt(env.ROWEL_SWEEP_INTERVAL_MS, SWEEP_INTERVAL_MS)
    this.maxCircuits = positiveInt(env.ROWEL_MAX_CIRCUITS, DEFAULT_MAX_CIRCUITS)
    // Armed here because this is the one place guaranteed to run.
    //
    // The first attempt armed it in `register`, which never fired: a Relay
    // whose machines all registered before this shipped registers no more of
    // them, so the alarm the orphans were waiting for was never set. Arming it
    // from each entry point instead worked, but only because `/healthz` happens
    // to be polled, and it put a write inside a read. A constructor runs on
    // every wake and asks for nothing in return.
    //
    // An Exchange holding nothing arms an alarm that finds nothing and does not
    // re-arm, so an idle Relay costs one alarm, once.
    ctx.blockConcurrencyWhile(async () => {
      if (await ctx.storage.getAlarm() === null) await ctx.storage.setAlarm(Date.now() + this.sweepInterval)
    })
  }

  /**
   * Coarse, non-identifying counters.
   * @returns the same four numbers the Node Relay's `/healthz` reports.
   */
  async health(): Promise<Health> {
    const counts = await this.counts()
    const since = await this.startedAt()
    return { ...counts, uptimeSeconds: Math.round((Date.now() - since) / 1000) }
  }

  /**
   * Is that machine online, and what is it called.
   * @param deviceId - the machine's device id.
   * @returns its display name and version, or that it is offline.
   */
  async describe(deviceId: string): Promise<MachineDescription> {
    const machine = await this.ctx.storage.get<MachineRow>(`m:${deviceId}`)
    return machine === undefined ? { online: false } : { online: true, name: machine.name, version: machine.version }
  }

  /**
   * Publish a Switchboard as the place to reach a machine.
   *
   * Displacement happens here rather than in the Switchboard because only this
   * object knows there was an earlier one: a laptop that suspends leaves a
   * half-dead socket in a Switchboard that has no idea it has been superseded.
   * @param deviceId - the machine's device id, already proven by signature.
   * @param name - display name.
   * @param version - Bridle version string.
   * @param switchboard - stringified id of the object holding the socket.
   * @returns accepted, or the capacity reason it was not.
   */
  async register(deviceId: string, name: string, version: string, switchboard: string): Promise<{ ok: true } | { ok: false; reason: string }> {
    const existing = await this.ctx.storage.get<MachineRow>(`m:${deviceId}`)
    // Checked after we know there is an incumbent, so a machine already using
    // this Relay never trips the ceiling on reconnect — shedding the people
    // already connected is the wrong half of the population to shed.
    const counts = await this.counts()
    if (existing === undefined && counts.machines >= this.maxMachines) {
      return { ok: false, reason: `this relay is holding its limit of ${String(this.maxMachines)} machines` }
    }
    if (existing !== undefined && existing.switchboard !== switchboard) {
      // The newest registration is by definition the one that can still carry
      // traffic, so the older socket goes, along with any phones on it.
      const stale = this.env.SWITCHBOARD.get(this.env.SWITCHBOARD.idFromString(existing.switchboard))
      this.ctx.waitUntil(stale.displace().catch(() => {
        // Already gone. That is the outcome we were asking for.
      }))
      // Once is a laptop waking up. Repeating every few seconds is two Bridles
      // holding the same key and displacing each other — a fight that is
      // invisible from either machine, because each side is "online" right up
      // until it is knocked off again. This line is the only vantage point
      // that can see both fighters.
      console.warn(`rowel-relay: ${deviceId} re-registered from a new connection after ${String(Date.now() - existing.since)}ms; displacing the old one`)
    }
    await this.ctx.storage.put(`m:${deviceId}`, { switchboard, name, version, since: Date.now(), circuits: 0 } satisfies MachineRow)
    return { ok: true }
  }

  /**
   * Drop a machine, but only if the Switchboard given is still the current one.
   * @param deviceId - the machine to drop.
   * @param switchboard - the object whose Bridle socket closed.
   */
  async unregister(deviceId: string, switchboard: string): Promise<void> {
    const machine = await this.ctx.storage.get<MachineRow>(`m:${deviceId}`)
    if (machine === undefined || machine.switchboard !== switchboard) return
    await this.ctx.storage.delete(`m:${deviceId}`)
  }

  /**
   * Where should this phone go, and may it.
   *
   * Order matters and matches the Node Relay: the rate limit is charged before
   * the lookup, so probing for which device ids exist costs the same as
   * connecting to one you own.
   * @param deviceId - the machine the phone asked for.
   * @param caller - the phone's address, for rate limiting.
   * @returns the Switchboard to forward the upgrade to, or a refusal.
   */
  async locate(deviceId: string, caller: string): Promise<AttachRoute | AttachRefusal> {
    if (!this.buckets.take(`attach:${caller}`, ATTACH_LIMIT)) {
      return { ok: false, code: 4029, reason: 'too many connections; wait a moment' }
    }
    const machine = await this.ctx.storage.get<MachineRow>(`m:${deviceId}`)
    if (machine === undefined) return { ok: false, code: 4404, reason: 'that machine is offline' }
    const counts = await this.counts()
    if (counts.circuits >= this.maxCircuits) {
      return { ok: false, code: 4008, reason: 'that machine already has the maximum number of devices attached' }
    }
    return { ok: true, switchboard: machine.switchboard }
  }

  /**
   * Mirror a Switchboard's circuit count into the census.
   *
   * The Switchboard is the authority — it can see its own sockets — so this
   * never decides anything, it only keeps `/healthz` honest.
   * @param deviceId - the machine whose count changed.
   * @param switchboard - the reporting object; a stale one is ignored.
   * @param delta - +1 on attach, -1 on detach.
   */
  async circuits(deviceId: string, switchboard: string, delta: number): Promise<void> {
    const machine = await this.ctx.storage.get<MachineRow>(`m:${deviceId}`)
    if (machine === undefined || machine.switchboard !== switchboard) return
    const next = Math.max(0, machine.circuits + delta)
    await this.ctx.storage.put(`m:${deviceId}`, { ...machine, circuits: next } satisfies MachineRow)
  }

  /**
   * Charge a short-code claim attempt against the caller's bucket.
   * @param caller - the claimant's address.
   * @returns whether the claim may proceed.
   */
  claimAllowance(caller: string): boolean {
    return this.buckets.take(`claim:${caller}`, CLAIM_LIMIT)
  }

  /**
   * Charge a Bridle connection against the caller's bucket.
   *
   * Charged before the Switchboard is created, because the Switchboard is the
   * cost: one fresh Durable Object per upgrade, holding a socket for up to
   * fifteen seconds whether or not anything registers.
   * @param caller - the connecting machine's address.
   * @returns whether the connection may proceed.
   */
  bridleAllowance(caller: string): boolean {
    return this.buckets.take(`bridle:${caller}`, BRIDLE_LIMIT)
  }

  /**
   * Take one of a machine's short-code slots.
   *
   * The bundle itself lives in the PairCode object the code names; only the
   * count can live here, because only here is there one place per machine to
   * count in.
   * @param deviceId - the machine publishing the offer.
   * @param code - the normalized short code.
   * @param expiresAt - when the slot lapses.
   * @returns whether the machine had a slot free.
   */
  async reserveOffer(deviceId: string, code: string, expiresAt: number): Promise<boolean> {
    const now = Date.now()
    const slots = this.live(await this.ctx.storage.get<OfferSlots>(`o:${deviceId}`), now)
    if (Object.keys(slots).length >= MAX_OFFERS_PER_DEVICE && slots[code] === undefined) return false
    slots[code] = expiresAt
    await this.setSlots(deviceId, slots)
    // One alarm for the whole object, always set to the soonest lapse. Without
    // it the census would only ever count offers upward: nothing tells this
    // object that a code nobody claimed has gone stale.
    const alarm = await this.ctx.storage.getAlarm()
    if (alarm === null || alarm > expiresAt) await this.ctx.storage.setAlarm(expiresAt)
    return true
  }

  /**
   * Give a slot back after a code was claimed.
   * @param deviceId - the machine that published it.
   * @param code - the code that was spent.
   */
  async releaseOffer(deviceId: string, code: string): Promise<void> {
    const slots = await this.ctx.storage.get<OfferSlots>(`o:${deviceId}`)
    if (slots === undefined || slots[code] === undefined) return
    delete slots[code]
    await this.setSlots(deviceId, slots)
  }

  /**
   * Sweep what nobody will come back for: lapsed offer slots, and machines
   * whose connection is gone.
   *
   * A directory row is retracted when the Bridle's socket closes, and that
   * close is not guaranteed to arrive — an evicted Worker, a laptop that
   * vanished, a runtime that never delivered the event. Until now the only
   * thing that noticed was a phone dialling that exact machine, which retracts
   * the row on its way to being refused. A device id nobody dials again was
   * therefore counted forever, and the count is what the ceiling is checked
   * against: enough orphans and this Relay refuses machines it has room for.
   *
   * Asking each row's object is one round trip per machine, and the number of
   * machines is the very thing the ceiling bounds — so the sweep costs no more
   * than the limit it protects.
   */
  override async alarm(): Promise<void> {
    const now = Date.now()
    let next = Infinity
    const all = await this.ctx.storage.list<OfferSlots>({ prefix: 'o:' })
    for (const [key, slots] of all) {
      const kept = this.live(slots, now)
      for (const expiresAt of Object.values(kept)) next = Math.min(next, expiresAt)
      if (Object.keys(kept).length === Object.keys(slots).length) continue
      await this.setSlots(key.slice(2), kept)
    }
    const orphans = await this.sweepMachines()
    // Re-armed while anything is held, so the next sweep happens whether or
    // not another offer is ever made.
    const rows = await this.ctx.storage.list({ prefix: 'm:' })
    if (rows.size > 0) next = Math.min(next, now + this.sweepInterval)
    if (next !== Infinity) await this.ctx.storage.setAlarm(next)
  }

  /**
   * Drop rows whose Switchboard no longer holds a Bridle.
   * @returns how many were dropped.
   */
  private async sweepMachines(): Promise<number> {
    const rows = await this.ctx.storage.list<MachineRow>({ prefix: 'm:' })
    let dropped = 0
    for (const [key, row] of rows) {
      let live = false
      try {
        const object = this.env.SWITCHBOARD.get(this.env.SWITCHBOARD.idFromString(row.switchboard))
        live = await object.holdsBridle()
      } catch {
        // An id that no longer resolves is as gone as an object that says so.
        live = false
      }
      if (live) continue
      await this.ctx.storage.delete(key)
      dropped += 1
    }
    return dropped
  }

  private live(slots: OfferSlots | undefined, now: number): OfferSlots {
    const kept: OfferSlots = {}
    for (const [code, expiresAt] of Object.entries(slots ?? {})) {
      if (expiresAt > now) kept[code] = expiresAt
    }
    return kept
  }

  private async setSlots(deviceId: string, slots: OfferSlots): Promise<void> {
    if (Object.keys(slots).length === 0) await this.ctx.storage.delete(`o:${deviceId}`)
    else await this.ctx.storage.put(`o:${deviceId}`, slots)
  }

  /**
   * Count what is actually stored, rather than keeping a tally beside it.
   *
   * The tally was the bug. `read → modify → write` is not atomic here: a
   * Durable Object lets other events run at every `await`, and `register`
   * kicks off a displacement that calls back in to `unregister`, so two paths
   * would each read the same number, each add their delta, and the second
   * write would erase the first. A lost decrement never comes back, so the
   * error only ever accumulated — observed drifting by one per restart until
   * the census claimed three machines where there was one. Left long enough it
   * would refuse new machines at a ceiling it had not actually reached.
   *
   * Deriving costs one list per census. The rows are small and there are as
   * many as there are machines using this Relay, which is the same number the
   * ceiling exists to bound — so the cost is bounded by the thing it measures.
   */
  private async counts(): Promise<Counts> {
    const machines = await this.ctx.storage.list<MachineRow>({ prefix: 'm:' })
    let circuits = 0
    for (const row of machines.values()) circuits += Math.max(0, row.circuits)
    const offers = await this.ctx.storage.list<OfferSlots>({ prefix: 'o:' })
    let live = 0
    const now = Date.now()
    for (const slots of offers.values()) live += Object.keys(this.live(slots, now)).length
    return { machines: machines.size, circuits, offers: live }
  }

  private async startedAt(): Promise<number> {
    const since = await this.ctx.storage.get<number>('since')
    if (since !== undefined) return since
    // Not process uptime — there is no process. This is when the Relay first
    // answered anything, which is the question `/healthz` was really asking.
    const now = Date.now()
    await this.ctx.storage.put('since', now)
    return now
  }
}
