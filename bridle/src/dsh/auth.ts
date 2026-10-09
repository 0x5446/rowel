/**
 * Trading dsh's launch token for the cookie it actually wants.
 *
 * dsh 0.2 prints one line when it is ready — `dsh web: <url>?token=<token>` —
 * and a `GET /?token=` with that token answers 303 with a signed cookie. That is
 * the whole official handshake, and the browser does it the same way.
 *
 * Only the token is taken from the line, never the address. From 0.2.1 a person
 * can configure a `publicUrl`, and the line then shows a reverse-proxy address
 * instead of loopback; the token is the same, and the exchange always goes to
 * the loopback address Bridle already knows. The cookie is bound to the Host it
 * is asked for on, so asking anywhere else would also get the wrong cookie.
 */

import { assertLoopback } from './client.ts'

/**
 * The token in a `dsh web:` line, or in a URL on its own.
 * @param text - the printed line, or a URL.
 * @returns the token, or undefined when there is none.
 */
export function tokenFrom(text: string): string | undefined {
  const url = /https?:\/\/\S+/u.exec(text)?.[0]
  if (url === undefined) return undefined
  try {
    const token = new URL(url).searchParams.get('token')
    return token === null || token === '' ? undefined : token
  } catch {
    return undefined
  }
}

/**
 * Exchange a launch token for a cookie at a loopback dsh.
 * @param base - the loopback base URL of that dsh.
 * @param token - the token it printed.
 * @returns the `name=value` cookie pair to send from now on.
 * @throws {@link Error} when dsh refuses the token or answers without a cookie.
 */
export async function exchangeToken(base: string, token: string): Promise<string> {
  const url = new URL('/', assertLoopback(base))
  url.searchParams.set('token', token)
  // Not followed: the redirect only leads to the page, and the cookie is on
  // the 303 itself.
  const response = await fetch(url, { redirect: 'manual', signal: AbortSignal.timeout(5_000) })
  if (response.status !== 303) {
    throw new Error(`dsh refused the token (HTTP ${String(response.status)}) — it changes every time dsh restarts`)
  }
  const cookie = response.headers.getSetCookie()
    .map(header => header.split(';')[0]?.trim() ?? '')
    .find(pair => pair.startsWith('dsh-auth-'))
  if (cookie === undefined) throw new Error('dsh accepted the token but sent no cookie')
  return cookie
}
