/**
 * Ringing a phone that is not attached.
 *
 * The Relay carries ciphertext and cannot read any of it, which is the property
 * the whole design rests on — and it is also why this file exists. A suspended
 * iOS app cannot be woken by anything except APNs, and APNs will only take a
 * push signed by the developer's key. That key cannot ship inside a Bridle
 * running on someone's laptop, because then every user would hold the key that
 * pushes to every other user. So the Relay signs, and the Relay is therefore
 * the one component that learns a device token.
 *
 * What it does not learn is what the push is about. The Bridle sends a token
 * and a machine name; the visible text is a constant in this file. There is no
 * field for the agent's question, so there is nothing to leak and no promise
 * resting on the Relay choosing not to look. The push is an alert and nothing
 * more: it does not run the app. When the person opens it, the app reconnects
 * over its own encrypted tunnel and shows the real request — words that never
 * crossed the Relay and never reached Apple.
 *
 * **Which host, and why nobody is asked.** A token is minted against either the
 * development or the production APNs host and is meaningless to the other. The
 * first version had the app work out which, by reading `aps-environment` out of
 * its own embedded provisioning profile, and pass the answer down through four
 * layers. That is a guess dressed as a fact — a Release build signed for
 * development is a sandbox token wearing a production badge — and it was
 * carried by three components that have no use for it. Apple already answers
 * the question: the wrong host replies `BadDeviceToken`. So this tries
 * production and falls back to sandbox, which costs one extra round trip for
 * development builds and nothing at all for the App Store, where every token is
 * a production token and the fallback never runs.
 *
 * **A refusal is not a death sentence.** Everything that is not a 200 used to
 * come back as `rejected`, and the Switchboard told the Bridle to forget the
 * token — so a rate limit, an expired signing key, or an Apple outage would
 * permanently delete a perfectly good address. Only Apple saying the device is
 * gone means the device is gone.
 *
 * Push is optional. A Relay with no key configured refuses to wake anyone;
 * every other function is unaffected.
 */

import type { Env } from './env.ts'

/** APNs hosts. Production first — see the header. */
const HOSTS = ['https://api.push.apple.com', 'https://api.sandbox.push.apple.com'] as const

/**
 * How long a signed APNs token is reused.
 *
 * Apple rejects a provider that mints these more than once every twenty
 * minutes and expires them after sixty, so the safe window is the middle of
 * that range rather than either edge.
 */
const JWT_LIFETIME_MS = 40 * 60 * 1000

/** The only words the Relay is able to say. */
const ALERT_BODY = 'Your agent is waiting on you.'

/** What a caller needs to ring one phone. */
export interface WakeTarget {
  token: string
  /** Shown after the body, so a person with two Macs knows which one stopped. */
  machine?: string
}

/**
 * Why a wake did not happen, or that it did.
 *
 * `dead` is separated from `refused` because only one of them is safe to act
 * on: the Bridle deletes the token it holds when it hears `dead`, and hearing
 * it for a rate limit would throw away a working address.
 */
export type WakeOutcome =
  | { ok: true }
  /** Apple says this device is gone. The token should be forgotten. */
  | { ok: false; reason: 'dead'; detail: string }
  /** Apple refused for some other reason. Keep the token; something is wrong here. */
  | { ok: false; reason: 'refused'; detail: string }
  /** No key, or a key that will not load. Nothing can be sent at all. */
  | { ok: false; reason: 'unconfigured'; detail: string }
  /** APNs could not be reached. */
  | { ok: false; reason: 'unreachable'; detail: string }

/** A signed provider token and when it stops being reused. */
interface CachedJwt {
  value: string
  mintedAt: number
  /** Which key it was signed with, so a rotated key is not reused stale. */
  keyId: string
}

let cached: CachedJwt | undefined
/**
 * The signing currently in flight.
 *
 * Without this, every request that arrives while the cache is cold mints its
 * own token — and Apple rejects a provider that mints more than one per twenty
 * minutes. The cold-start case is exactly the one where several arrive at once,
 * because a Worker that has just woken is a Worker that had a queue.
 */
let minting: Promise<string> | undefined

/**
 * Send one content-free push.
 * @param env - the Worker environment, for the APNs key material.
 * @param target - who to ring.
 * @param now - current epoch milliseconds; injectable so a test is not timed.
 * @returns whether APNs accepted it, and why not when it did not.
 */
export async function wake(env: Env, target: WakeTarget, now: number = Date.now()): Promise<WakeOutcome> {
  const key = env.ROWEL_APNS_KEY
  const keyId = env.ROWEL_APNS_KEY_ID
  const teamId = env.ROWEL_APNS_TEAM_ID
  const topic = env.ROWEL_APNS_TOPIC
  if (!key && !keyId && !teamId && !topic) return { ok: false, reason: 'unconfigured', detail: 'push is not configured' }
  // Some but not all is a different thing from none, and has to be loud: it is
  // a deployment someone meant to finish, and every push silently disappears
  // until they do.
  if (!key || !keyId || !teamId || !topic) {
    return { ok: false, reason: 'unconfigured', detail: 'push is half-configured; some APNs settings are missing' }
  }
  if (!/^[0-9a-f]{64,200}$/u.test(target.token)) return { ok: false, reason: 'dead', detail: 'malformed token' }

  let jwt: string
  try {
    jwt = await providerToken(key, keyId, teamId, now)
  } catch (error) {
    return { ok: false, reason: 'unconfigured', detail: `APNs key will not load: ${describe(error)}` }
  }

  // `alert`, not `content-available`. A silent push is the tempting design —
  // wake, fetch, post the real text — but iOS treats silent pushes as
  // discardable: throttled, dropped in Low Power Mode, never delivered at all
  // once the app has been force-quit. A notification that arrives when the
  // system feels like it is not a notification for "may I delete this".
  const body = JSON.stringify({
    aps: {
      alert: {
        title: 'Rowel',
        body: target.machine === undefined ? ALERT_BODY : `${ALERT_BODY} · ${target.machine}`,
      },
      sound: 'default',
      'interruption-level': 'time-sensitive',
    },
  })
  const headers = {
    authorization: `bearer ${jwt}`,
    'apns-topic': topic,
    'apns-push-type': 'alert',
    'apns-priority': '10',
    // A wake that arrives an hour late is worse than one that never arrives:
    // the person opens the app to find the question already answered or the
    // agent long since given up.
    'apns-expiration': String(Math.floor(now / 1000) + 300),
  }

  let last: Extract<WakeOutcome, { ok: false }> = { ok: false, reason: 'unreachable', detail: 'no host was tried' }
  // Whether production itself called the token bad, as opposed to never having
  // been asked. Sandbox says `BadDeviceToken` about every production token
  // there is, so its answer only means anything once production has agreed.
  let productionRefusedToken = false

  for (const host of HOSTS) {
    const isProduction = host === HOSTS[0]
    let response: Response
    try {
      response = await fetch(`${host}/3/device/${target.token}`, { method: 'POST', headers, body })
    } catch (error) {
      last = { ok: false, reason: 'unreachable', detail: describe(error) }
      continue
    }
    if (response.status === 200) return { ok: true }
    const outcome = classify(response.status, await response.text().catch(() => ''))
    const badToken = outcome.reason === 'dead' && outcome.detail.includes('BadDeviceToken')

    // `BadDeviceToken` from production is the ordinary answer for a development
    // token, so it is the one refusal worth asking the other host about. Every
    // other refusal means the same thing on both, and asking twice would only
    // double the load on an Apple that is already unhappy.
    if (isProduction && badToken) {
      productionRefusedToken = true
      last = outcome
      continue
    }

    // Sandbox refusing a token that production never got to see proves nothing
    // — and reporting it as `dead` would have the Bridle delete a working
    // address over one network blip. The previous version did exactly that:
    // production `fetch` threw, the loop fell through to sandbox, and sandbox's
    // routine refusal of a live production token was returned as a death
    // certificate. The comment above already claimed both hosts had to agree;
    // nothing was recording whether they had.
    if (badToken && !productionRefusedToken) {
      return { ok: false, reason: 'refused', detail: `${outcome.detail} (production was never reached)` }
    }
    return outcome
  }
  return last
}

/** Drop the cached provider token. Only a test needs this. */
export function forgetProviderToken(): void {
  cached = undefined
  minting = undefined
}

/**
 * Decide what an APNs refusal means for the token.
 * @param status - the HTTP status.
 * @param payload - the response body, which carries Apple's `reason`.
 * @returns a `dead` outcome only when Apple says the device is gone.
 */
function classify(status: number, payload: string): Extract<WakeOutcome, { ok: false }> {
  let reason = ''
  try {
    reason = String((JSON.parse(payload) as { reason?: unknown }).reason ?? '')
  } catch {
    // Apple answers JSON; anything else is a proxy or an outage page, and
    // either way it is not Apple telling us the device is gone.
  }
  const detail = `${String(status)} ${reason || payload}`.trim()
  // 410 is unambiguous: the app was uninstalled. `BadDeviceToken` is not — it
  // is also what the wrong host says about a perfectly live device — so it is
  // only fatal after both hosts have said it, which the loop in `wake` decides.
  if (status === 410 || reason === 'Unregistered' || reason === 'BadDeviceToken') {
    return { ok: false, reason: 'dead', detail }
  }
  return { ok: false, reason: 'refused', detail }
}

/**
 * Sign, or reuse, the provider token APNs authenticates with.
 * @param pem - the `.p8` contents.
 * @param keyId - the key's ten-character id.
 * @param teamId - the paid team's ten-character id.
 * @param now - current epoch milliseconds.
 * @returns a compact ES256 JWT.
 */
async function providerToken(pem: string, keyId: string, teamId: string, now: number): Promise<string> {
  if (cached !== undefined && cached.keyId === keyId && now - cached.mintedAt < JWT_LIFETIME_MS) return cached.value
  minting ??= sign(pem, keyId, teamId, now).finally(() => { minting = undefined })
  return await minting
}

/**
 * @param pem - the `.p8` contents.
 * @param keyId - the key's id, which goes in the header.
 * @param teamId - the team's id, which goes in the claims.
 * @param now - current epoch milliseconds.
 * @returns the signed token, also placed in the cache.
 */
async function sign(pem: string, keyId: string, teamId: string, now: number): Promise<string> {
  const key = await crypto.subtle.importKey(
    'pkcs8',
    pkcs8(pem),
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['sign'],
  )
  const header = base64url(new TextEncoder().encode(JSON.stringify({ alg: 'ES256', kid: keyId })))
  const claims = base64url(new TextEncoder().encode(JSON.stringify({ iss: teamId, iat: Math.floor(now / 1000) })))
  const signed = `${header}.${claims}`
  const signature = await crypto.subtle.sign(
    { name: 'ECDSA', hash: 'SHA-256' },
    key,
    new TextEncoder().encode(signed),
  )
  const value = `${signed}.${base64url(new Uint8Array(signature))}`
  cached = { value, mintedAt: now, keyId }
  return value
}

/**
 * Strip a PEM envelope down to the DER it wraps.
 * @param pem - the `.p8` file contents, newlines optional.
 * @returns the raw PKCS#8 bytes.
 */
function pkcs8(pem: string): Uint8Array {
  const base64 = pem.replace(/-----[A-Z ]+-----/gu, '').replace(/\s+/gu, '')
  const binary = atob(base64)
  const bytes = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i)
  return bytes
}

/**
 * Base64url without padding, which is what JWT requires.
 * @param bytes - what to encode.
 * @returns the encoded string.
 */
function base64url(bytes: Uint8Array): string {
  let binary = ''
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return btoa(binary).replace(/\+/gu, '-').replace(/\//gu, '_').replace(/=+$/u, '')
}

/**
 * @param error - anything thrown.
 * @returns a short operator-facing string.
 */
function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
