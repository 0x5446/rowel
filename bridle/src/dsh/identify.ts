/**
 * Which dsh is on the other end, and whether Bridle may talk to it.
 *
 * Asked before anything else, because the two generations of dsh share nothing
 * a client could fall back on: dsh 0.1.1 answers its dotted methods to anyone
 * on loopback, and everything from 0.1.2 on refuses all of `/api` without a
 * cookie. A refusal says "sign in", not "which version" — 0.1.2 through 0.1.7
 * were transitions with their own method sets and refuse exactly the same way —
 * so the version is only ever read, from `pluginManager/listBundles`, once
 * signed in. Never inferred: a dsh whose version cannot be read is reported as
 * that, not assumed to be the one we hope for.
 */

import { assertLoopback } from './client.ts'
import { forgetCookie } from './credentials.ts'

/** What a dsh address turned out to be. */
export type DshIdentity =
  /** dsh 0.1.1 or older: answers without credentials. */
  | { kind: 'legacy' }
  /** A dsh that wants a cookie Bridle does not have, or refused the one it has. */
  | { kind: 'locked' }
  /** Signed in, and the version is known. */
  | { kind: 'signed-in'; version: string }
  /** Not a dsh, or one whose version could not be read. */
  | { kind: 'unknown'; detail: string }

/** The bundle whose version is dsh's version. */
const CORE_BUNDLE = '@deepseek-ai/dsh-base'

/**
 * Identify the dsh at a loopback address.
 * @param base - the loopback base URL.
 * @param cookie - the cookie to sign in with, when one is known.
 * @returns what answered there.
 */
export async function identifyDsh(base: string, cookie?: string): Promise<DshIdentity> {
  const origin = assertLoopback(base)
  // The 0.1 method, without credentials: only 0.1.1 and older answer it.
  let open: Response
  try {
    open = await post(origin, 'session.list', {})
  } catch (error) {
    return { kind: 'unknown', detail: describe(error) }
  }
  if (open.ok) {
    const body = await open.json().catch(() => undefined) as { type?: unknown } | undefined
    return body?.type === 'server-response'
      ? { kind: 'legacy' }
      : { kind: 'unknown', detail: 'answered, but not the way dsh does' }
  }
  if (open.status !== 401) return { kind: 'unknown', detail: `HTTP ${String(open.status)} where dsh would answer or ask to sign in` }
  // Plenty of local services answer 401. Taking every one for a dsh would bind
  // Bridle to the wrong port — and send that service the cookie. dsh says who
  // it is when its page refuses: "dsh web authentication required; …".
  if (!await asksForDshSignIn(origin)) return { kind: 'unknown', detail: 'asks to sign in, but not the way dsh does' }
  if (cookie === undefined) return { kind: 'locked' }

  let bundles: Response
  try {
    bundles = await post(origin, 'pluginManager/listBundles', { args: {} }, cookie)
  } catch (error) {
    return { kind: 'unknown', detail: describe(error) }
  }
  if (bundles.status === 401) {
    forgetCookie(origin.origin, cookie)
    return { kind: 'locked' }
  }
  const body = await bundles.json().catch(() => undefined) as
    { result?: { ok?: boolean; value?: unknown } } | undefined
  const list = body?.result?.ok === true && Array.isArray(body.result.value) ? body.result.value as unknown[] : []
  const core = list.find((entry): entry is { version: unknown } =>
    typeof entry === 'object' && entry !== null && (entry as { name?: unknown }).name === CORE_BUNDLE)
  return typeof core?.version === 'string'
    ? { kind: 'signed-in', version: core.version }
    : { kind: 'unknown', detail: 'signed in, but dsh did not say which version it is' }
}

/**
 * Whether a dsh version speaks the API this Bridle is moving to (0.2 and
 * later). Pre-releases of 0.2 count: `0.2.0-rc.2` is the 0.2 API, and is what
 * npm installs today.
 * @param version - a version string such as `0.2.0-rc.2`.
 * @returns true for 0.2 and later.
 */
export function speaksCurrentApi(version: string): boolean {
  const match = /^(\d+)\.(\d+)\./u.exec(version)
  if (match === null) return false
  const major = Number(match[1])
  const minor = Number(match[2])
  return major > 0 || minor >= 2
}

/**
 * One sentence for a person, saying what the identity means.
 * @param identity - what {@link identifyDsh} found.
 * @returns the description.
 */
export function describeIdentity(identity: DshIdentity): string {
  switch (identity.kind) {
    case 'legacy':
      return 'dsh 0.1.1 or older (no sign-in)'
    case 'locked':
      return 'dsh 0.1.2 or newer, not signed in — run "bridle plugin install" and restart dsh, or let bridle start dsh itself'
    case 'signed-in':
      // Until M1 of docs/dsh-0.2-migration.md: signed in, but the rest of
      // this Bridle still speaks the 0.1 API. Delete the note with the switch.
      return `dsh ${identity.version}${speaksCurrentApi(identity.version)
        ? ' (signed in; this Bridle cannot serve dsh 0.2 yet — keep dsh 0.1.1 for now)'
        : ' (a pre-0.2 transition release; update dsh)'}`
    case 'unknown':
      return `not identified (${identity.detail})`
  }
}

async function asksForDshSignIn(origin: URL): Promise<boolean> {
  try {
    const page = await fetch(new URL('/', origin), { redirect: 'manual', signal: AbortSignal.timeout(3_000) })
    return page.status === 401 && (await page.text()).includes('dsh web')
  } catch {
    return false
  }
}

function post(origin: URL, method: string, payload: unknown, cookie?: string): Promise<Response> {
  return fetch(new URL(`/api/${method}`, origin), {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...(cookie === undefined ? {} : { cookie }) },
    body: JSON.stringify({ type: 'client-request', rpcId: 'bridle-identify', method, payload }),
    signal: AbortSignal.timeout(3_000),
  })
}

function describe(error: unknown): string {
  if (!(error instanceof Error)) return String(error)
  const cause = error.cause instanceof Error ? `: ${error.cause.message}` : ''
  return `${error.message}${cause}`
}
