/**
 * The cookies that get Bridle past dsh's door, one per address.
 *
 * dsh 0.2 lets nothing into `/api` — loopback included — without a signed
 * cookie, and the only way to get one is to trade the token dsh prints when it
 * starts (`auth.ts`). The token changes on every dsh restart; the cookie does
 * not: it is signed with a key kept in `$DSH_HOME`, lasts thirty days and
 * survives restarts. So a cookie is the thing worth keeping, and keeping it is
 * what lets a Bridle that restarts — or finds a dsh an earlier Bridle started —
 * carry on without a token it can no longer see.
 *
 * Kept by authority (`host:port`) because dsh names the cookie after the Host
 * it was issued for: the cookie for `127.0.0.1:3080` is not accepted on
 * `localhost:3080`, nor on `127.0.0.1:3081`.
 *
 * Process-wide, because the two doorways learn the cookie in different places
 * and must share it: the dsh plugin is handed a token by dsh some time after
 * the Bridle in it has built its client, and the client asks here on every
 * request rather than holding a copy that would go stale.
 */

import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { rowelHome } from '../identity.ts'

/** authority → `name=value`, as sent in a `cookie` header. */
let cookies: Map<string, string> | undefined

function storePath(): string {
  return join(rowelHome(), 'secrets', 'dsh-cookies.json')
}

/** The address part a cookie is bound to, e.g. `127.0.0.1:3080`. */
function authority(base: string): string {
  return new URL(base).host
}

function loaded(): Map<string, string> {
  if (cookies !== undefined) return cookies
  cookies = readStore()
  return cookies
}

/** The file as it is now. */
function readStore(): Map<string, string> {
  const store = new Map<string, string>()
  try {
    const saved = JSON.parse(readFileSync(storePath(), 'utf8')) as Record<string, unknown>
    for (const [key, value] of Object.entries(saved)) {
      if (typeof value === 'string') store.set(key, value)
    }
  } catch {
    // None saved yet, or unreadable: either way there is nothing to reuse.
  }
  return store
}

/**
 * Change one entry, on top of what is on disk now.
 *
 * Two processes write this file — the dsh plugin and a `bridle status` typed
 * in a terminal — and each holds its own copy in memory. Writing a whole copy
 * back would undo the other's change: a terminal dropping a stale cookie would
 * put back the table it read before the plugin saved a fresh one. So the file
 * is re-read and only the one entry changes.
 */
function change(mutate: (store: Map<string, string>) => boolean): void {
  const memory = loaded()
  mutate(memory)
  const disk = readStore()
  if (mutate(disk)) persist(disk)
}

function persist(store: Map<string, string>): void {
  // Never a throw: a cookie that could not be written is a cookie that has to
  // be fetched again next time, not a reason to take down the Bridle (or, in
  // the plugin, the dsh it lives in).
  try {
    const directory = join(rowelHome(), 'secrets')
    mkdirSync(directory, { recursive: true, mode: 0o700 })
    const path = storePath()
    const temporary = `${path}.${String(process.pid)}.tmp`
    writeFileSync(temporary, `${JSON.stringify(Object.fromEntries(store), null, 2)}\n`, { mode: 0o600 })
    renameSync(temporary, path)
  } catch {
    // See above.
  }
}

/**
 * The cookie for a dsh address, if one is known.
 * @param base - the dsh base URL.
 * @returns the `name=value` pair, or undefined.
 */
export function cookieFor(base: string): string | undefined {
  return loaded().get(authority(base))
}

/**
 * Keep a cookie for a dsh address, in memory and on disk.
 * @param base - the dsh base URL it was issued for.
 * @param cookie - the `name=value` pair.
 */
export function rememberCookie(base: string, cookie: string): void {
  const key = authority(base)
  change((store) => {
    if (store.get(key) === cookie) return false
    store.set(key, cookie)
    return true
  })
}

/**
 * Drop a cookie dsh refused — it expired, or the key behind it was replaced.
 *
 * Only that cookie: a request still in flight with an old one can be refused
 * after a fresh one has been saved, and must not take the fresh one with it.
 * @param base - the dsh base URL.
 * @param refused - the `name=value` pair that was refused.
 */
export function forgetCookie(base: string, refused: string): void {
  const key = authority(base)
  change((store) => store.get(key) === refused && store.delete(key))
}
