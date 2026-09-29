/**
 * Pairing payloads. Two paths, both ending in a mutually authenticated tunnel:
 *
 * - **QR** carries the Bridle's static public key and a token that leaves the
 *   Mac only inside the QR, so a hostile Relay can neither interpose nor pair
 *   itself. This is the default and needs no confirmation step.
 * - **Short code** is for people who cannot scan. The phone fetches the bundle
 *   from the Relay, which could lie or use it itself, so its token only earns a
 *   request: the Mac shows the requesting device's key fingerprint and a person
 *   accepts only if it matches the one the phone shows (`bridle pair --code`).
 */

import { createHash, randomBytes } from 'node:crypto'

/** How long a pairing offer stays claimable. */
export const PAIRING_TTL_MS = 10 * 60 * 1000

/** Digits in the out-of-band confirmation number. */
const FINGERPRINT_DIGITS = 6

/** Characters of the typed short code: no vowels (no accidental words) and no 0/O/1/I/L. */
const CODE_ALPHABET = 'BCDFGHJKMNPQRSTVWXYZ23456789'

/** Everything the phone needs to reach and authenticate one Bridle. */
export interface PairingBundle {
  /** Payload format version. */
  v: number
  /** Relay base URL. Always present: it is the path that works from anywhere. */
  relay: string
  /**
   * LAN addresses of the Bridle's direct listener, best candidate first. The
   * app races these against the Relay and keeps whichever answers, so being on
   * the same Wi-Fi costs one local round trip instead of a trip to the Relay.
   */
  direct?: string[]
  /** Stable per-machine identifier used by the Relay to pair the two sockets. */
  device: string
  /** Bridle's raw static public key, base64url. */
  key: string
  /** One-time pairing token, base64url; consumed by the first successful handshake. */
  token: string
  /** Display name of the machine, shown in the app's machine switcher. */
  name: string
}

/**
 * Mint a fresh one-time pairing token.
 * @returns 16 random bytes, base64url encoded.
 */
export function mintPairingToken(): string {
  return randomBytes(16).toString('base64url')
}

/**
 * Mint a typed short code carrying the same entropy as a claim ticket.
 * @returns an eight-character code in the unambiguous alphabet, hyphenated.
 */
export function mintShortCode(): string {
  const bytes = randomBytes(8)
  let code = ''
  for (const byte of bytes) code += CODE_ALPHABET[byte % CODE_ALPHABET.length]
  return `${code.slice(0, 4)}-${code.slice(4)}`
}

/**
 * Normalize a user-typed short code for comparison.
 * @param input - whatever the user typed.
 * @returns the code in canonical hyphenated uppercase form.
 */
export function normalizeShortCode(input: string): string {
  const stripped = input.toUpperCase().replaceAll(/[^A-Z0-9]/gu, '')
  return stripped.length === 8 ? `${stripped.slice(0, 4)}-${stripped.slice(4)}` : stripped
}

/**
 * Encode a bundle as the deep link the QR image carries. The payload sits in
 * the fragment so it never reaches a web server if the link is ever opened in
 * a browser instead of the app.
 * @param bundle - the pairing bundle.
 * @returns a `rowel://pair#...` URL.
 */
export function encodePairingLink(bundle: PairingBundle): string {
  return `rowel://pair#${Buffer.from(JSON.stringify(bundle), 'utf8').toString('base64url')}`
}

/**
 * Decode a pairing deep link.
 * @param link - the scanned or pasted URL.
 * @returns the bundle it carries.
 * @throws {@link Error} when the link is not a well-formed Rowel pairing link.
 */
export function decodePairingLink(link: string): PairingBundle {
  const marker = '#'
  const at = link.indexOf(marker)
  if (!link.startsWith('rowel://pair') || at < 0) throw new Error('not a Rowel pairing link')
  const parsed: unknown = JSON.parse(Buffer.from(link.slice(at + 1), 'base64url').toString('utf8'))
  if (typeof parsed !== 'object' || parsed === null) throw new Error('pairing link payload is not an object')
  const bundle = parsed as PairingBundle
  for (const field of ['relay', 'device', 'key', 'token', 'name'] as const) {
    if (typeof bundle[field] !== 'string' || bundle[field].length === 0) {
      throw new Error(`pairing link is missing ${field}`)
    }
  }
  return bundle
}

/**
 * Six-digit number derived from the completed handshake hash — identical on
 * both ends exactly when no one sits in the middle. Kept with its test vectors,
 * but not part of either pairing flow: the Mac never computed it, and the
 * short-code path is guarded by a fingerprint check instead (docs/protocol.md §2.5).
 * @param handshakeHash - the Noise handshake hash of the established channel.
 * @returns a zero-padded six-digit string.
 */
export function confirmationNumber(handshakeHash: Buffer): string {
  const digest = createHash('sha256').update('rowel-confirm').update(handshakeHash).digest()
  const value = digest.readUInt32BE(0) % 10 ** FINGERPRINT_DIGITS
  return String(value).padStart(FINGERPRINT_DIGITS, '0')
}

/**
 * Short, human-comparable rendering of a peer's static key for the trust screen.
 * @param publicKey - raw 32-byte static public key.
 * @returns four hyphen-separated four-character groups.
 */
export function keyFingerprint(publicKey: Buffer): string {
  const digest = createHash('sha256').update('rowel-identity').update(publicKey).digest('hex').toUpperCase()
  return [0, 4, 8, 12].map(offset => digest.slice(offset, offset + 4)).join('-')
}
