/**
 * The numbers the Relay is held to.
 *
 * The first block is protocol (docs/protocol.md §6.2): the Bridle and the app
 * are already shipped against these, so they are constants here rather than
 * configuration — loosening one makes abuse cheaper without telling anybody.
 * The second block is capacity, which depends on what you are willing to pay
 * for, so it comes from the environment.
 */

/** How long a Bridle has to answer the registration challenge. */
export const REGISTER_TIMEOUT_MS = 15_000

/** Phones one machine may hold at once. */
export const MAX_CIRCUITS_PER_MACHINE = 8

/** Unclaimed short codes one machine may hold at once. */
export const MAX_OFFERS_PER_DEVICE = 3

/** Ceiling on how long the Relay will hold a pairing offer. */
export const OFFER_MAX_TTL_MS = 15 * 60 * 1000

/** Largest `POST /v1/pair/offer` body that will be read. */
export const MAX_BODY_BYTES = 64 * 1024

/**
 * Largest tunnel message this substrate can carry, in bytes.
 *
 * **Lower than the protocol's own ceiling, and not by choice.** docs/protocol.md
 * §6.2 says 64 MiB; the Workers runtime closes any WebSocket that receives a
 * message over 32 MiB with a 1009 before a single line of this code runs, so
 * that number cannot be honoured here. Nothing below enforces it — the
 * enforcement is the runtime's, and the Relay only gets to describe it.
 *
 * @see https://developers.cloudflare.com/workers/runtime-apis/websockets/
 */
export const RUNTIME_MAX_FRAME_BYTES = 32 * 1024 * 1024

/** Machines the whole Relay will hold at once, when `ROWEL_MAX_MACHINES` is unset. */
/**
 * How often the Exchange checks its directory against reality.
 *
 * A row is retracted when the Bridle's socket closes, and that close is not
 * guaranteed: an evicted Worker or a laptop that simply vanished leaves a row
 * behind. Ten minutes is short enough that the census is never far wrong and
 * long enough that the sweep costs nothing — one round trip per machine, at
 * most six times an hour.
 */
export const SWEEP_INTERVAL_MS = 10 * 60 * 1000

export const DEFAULT_MAX_MACHINES = 1_000

/** Circuits across every machine, when `ROWEL_MAX_CIRCUITS` is unset. */
export const DEFAULT_MAX_CIRCUITS = 4_000

/** Burst and refill for `GET /v1/pair/claim`, per caller address. */
export const CLAIM_LIMIT = { capacity: 10, refillPerSecond: 0.2 } as const

/** Burst and refill for `WS /v1/app`, per caller address. */
export const ATTACH_LIMIT = { capacity: 30, refillPerSecond: 1 } as const

/**
 * Bridle connections per caller.
 *
 * The bridle door was the one unmetered entrance — and here it is the most
 * expensive door in the building: every upgrade mints a fresh Durable Object
 * that holds a socket for up to fifteen seconds. A healthy Bridle connects
 * once and redials with backoff, so the phone allowance is generous; the
 * burst absorbs an office of machines reconnecting through one NAT.
 */
export const BRIDLE_LIMIT = { capacity: 30, refillPerSecond: 1 } as const

/**
 * Read a positive integer out of a Worker variable.
 * @param raw - the configured value, if any.
 * @param fallback - used when unset, empty, or not a positive integer.
 * @returns the limit to enforce.
 */
export function positiveInt(raw: string | undefined, fallback: number): number {
  const value = Number(raw)
  return Number.isInteger(value) && value > 0 ? value : fallback
}

/**
 * Burst and refill for wakes, per machine. A registered Bridle is only a key
 * someone generated, and a wake is a time-sensitive notification on somebody's
 * phone plus a call against this deployment's APNs quota — so a machine gets a
 * few in a burst and about one every six seconds after. A real one rings for a
 * question at a time.
 */
export const WAKE_LIMIT = { capacity: 5, refillPerSecond: 10 / 60 } as const

/** Longest machine name a wake may put in a notification, in characters. */
export const MAX_WAKE_MACHINE_CHARS = 64
