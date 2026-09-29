/**
 * Making a machine claimable by a phone.
 *
 * Two paths, and they do not trust the same things. Scanning the QR is the
 * default: the code carries the machine's static key and a token that never
 * leaves this machine any other way, so a phone presenting that token scanned
 * this screen, and a hostile Relay can neither impersonate the machine nor
 * pair itself.
 *
 * Typing the short code exists because some people will be pairing an iPad,
 * or a phone whose camera is covered by a corporate policy. Its bundle is
 * handed to the Relay, which could read the token in it, swap the key, or
 * present the token itself. So that token only ever earns a *claim*: the
 * Bridle records the claiming device and refuses it, and `bridle pair --code`
 * shows its fingerprint to the person at the Mac, who accepts it only if it
 * matches the one on their phone. One comparison covers both attacks — a
 * Relay pairing itself shows its own key, and a Relay sitting in the middle
 * shows its own key too.
 */

import {
  deviceIdFor,
  encodePairingLink,
  signPairOffer,
  type PairingBundle,
} from '@rowel/protocol'
import { openPairingOffer, signingKeys, staticKeys, type BridleState } from './identity.ts'

/** Everything the operator needs to show, in the three forms a person might use. */
export interface Invitation {
  /** The full bundle, for the QR. */
  bundle: PairingBundle
  /** `rowel://pair#…` deep link the QR encodes. */
  link: string
  /** Typed alternative, e.g. `KTPQ-3WRM`. */
  code: string
  /** The token the short-code bundle carries instead of the QR's. */
  codeToken: string
  /** Epoch milliseconds after which the invitation stops working. */
  expiresAt: number
}

/**
 * Open a pairing invitation for this machine.
 * @param state - loaded state; the offer is recorded and persisted.
 * @param direct - LAN tunnel addresses to advertise, if the daemon has any.
 * @returns the invitation in all three forms.
 */
export function createInvitation(state: BridleState, direct: string[] = []): Invitation {
  const offer = openPairingOffer(state)
  const bundle: PairingBundle = {
    v: 1,
    relay: state.relayUrl,
    ...(direct.length > 0 ? { direct } : {}),
    device: state.deviceId,
    key: staticKeys(state).publicKey.toString('base64url'),
    token: offer.token,
    name: state.machineName,
  }
  return { bundle, link: encodePairingLink(bundle), code: offer.code, codeToken: offer.codeToken, expiresAt: offer.expiresAt }
}

/**
 * Hand the invitation to the Relay so a typed short code can fetch it.
 *
 * With the short-code token, never the QR's: whatever is published here the
 * Relay can read, and the QR token is the one thing this Bridle accepts
 * without asking a person.
 * @param state - loaded state, for the signing identity.
 * @param invitation - the invitation to publish.
 * @throws {@link Error} when the Relay refuses the offer.
 */
export async function publishInvitation(state: BridleState, invitation: Invitation): Promise<void> {
  const keys = signingKeys(state)
  const response = await fetch(new URL('/v1/pair/offer', toHttpUrl(state.relayUrl)), {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      code: invitation.code,
      device: deviceIdFor(keys.publicKey),
      key: keys.publicKey.toString('base64url'),
      signature: signPairOffer(keys.privateKey, invitation.code),
      bundle: { ...invitation.bundle, token: invitation.codeToken },
      expiresAt: invitation.expiresAt,
    }),
    signal: AbortSignal.timeout(10_000),
  })
  if (!response.ok) {
    throw new Error(`relay refused the pairing offer (HTTP ${String(response.status)})`)
  }
}

/**
 * Normalize a Relay base URL to an HTTP scheme.
 * @param base - an `http(s)://` or `ws(s)://` URL.
 * @returns the same origin with an HTTP scheme.
 */
export function toHttpUrl(base: string): string {
  const url = new URL(base)
  if (url.protocol === 'ws:') url.protocol = 'http:'
  else if (url.protocol === 'wss:') url.protocol = 'https:'
  return url.toString()
}
