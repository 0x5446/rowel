/**
 * The Bridle's outbound connection to a Relay.
 *
 * Outbound is the whole point: a laptop behind NAT, a corporate network, or a
 * captive café Wi-Fi cannot accept inbound connections, and asking a user to
 * forward a port would end the product right there. So the Bridle dials out and
 * holds one socket, and the Relay switches phones onto it.
 *
 * The Relay sees ciphertext and circuit numbers. It cannot read a single byte
 * of what passes through, and this client never gives it the chance.
 */

import WebSocket from 'ws'
import {
  MuxType,
  decodeMux,
  deviceIdFor,
  encodeMux,
  signRegistration,
} from '@rowel/protocol'
import { TunnelSession } from './tunnel/session.ts'
import { signingKeys } from './identity.ts'
import type { BridleCore } from './core.ts'

/** Backoff floor between redials. */
const RETRY_MIN_MS = 1_000

/** Backoff ceiling; a laptop that sleeps for hours should not hammer the Relay on wake. */
const RETRY_MAX_MS = 30_000

/**
 * How long a connection must survive before its backoff is forgiven.
 *
 * Forgiving on registration was the accelerant in an identity fight: when two
 * Bridles hold the same key, each registration succeeds — and displaces the
 * other — so both reset to the floor and the pair hammered the Relay at a
 * couple of seconds per round, forever, invisibly. In that fight each side
 * stays online for exactly as long as the other waits to redial, which is at
 * most the ceiling — so the bar to clear has to sit above the ceiling, or the
 * fight earns its speed back.
 */
const STABLE_MS = RETRY_MAX_MS * 2

/** Carrier-level keepalive, well under the usual 60s idle timeout of a proxy. */
const KEEPALIVE_MS = 20_000

/**
 * How long the Relay may say nothing at all before its socket is presumed dead.
 *
 * Pinging without ever reading the answer is not a keepalive, it is a habit.
 * A Mac that changes networks — hotspot to Wi-Fi, or a sleep and a wake — keeps
 * a socket object whose TCP flow is already gone: no RST arrives, no `close`
 * event fires, `ping()` writes into a buffer nobody drains, and this client
 * goes on publishing `online` forever. The Relay meanwhile lost the socket, so
 * every phone that dials is turned away with 4404 "that machine is offline"
 * while `bridle status` and `runtime.json` insist the machine is up. Nothing
 * anywhere reports a fault, and only a manual restart clears it.
 *
 * Three keepalives' worth of silence, because the pong is the only thing the
 * Relay sends an idle Bridle and one lost round trip is not evidence.
 */
const SILENCE_LIMIT_MS = KEEPALIVE_MS * 3

/** How long the Relay has to answer the registration handshake. */
const REGISTER_TIMEOUT_MS = 15_000

/** Relay control messages exchanged before the socket goes binary. */
interface RelayControl {
  t: 'challenge' | 'registered' | 'error'
  nonce?: string
  device?: string
  message?: string
}

/** Reportable connection state, surfaced by `bridle status`. */
export type RelayState = 'offline' | 'connecting' | 'online'

/** Options for {@link RelayClient}. */
export interface RelayClientOptions {
  /** Bridle package version, reported to the app and the Relay. */
  version: string
  /** Progress and error reporting. */
  log?: (message: string) => void
  /** Called on every state transition. */
  onState?: (state: RelayState, detail?: string) => void
  /** Override for {@link STABLE_MS}, so a test does not wait a minute. */
  stableMs?: number
  /** Override for {@link KEEPALIVE_MS}, so a test does not wait twenty seconds. */
  keepaliveMs?: number
  /** Override for {@link SILENCE_LIMIT_MS}, so a test does not wait a minute. */
  silenceMs?: number
}

/** Holds one Relay socket and the tunnels multiplexed over it. */
export class RelayClient {
  private socket: WebSocket | undefined
  private readonly circuits = new Map<number, TunnelSession>()
  private readonly abort = new AbortController()
  private retry = RETRY_MIN_MS
  private state: RelayState = 'offline'
  private keepalive: NodeJS.Timeout | undefined
  private unwatchWaiting: (() => void) | undefined
  /** Whether the current socket has finished registering. */
  private registered = false
  /** When the current socket registered, for deciding whether it earned a backoff reset. */
  private onlineAt: number | undefined

  /**
   * @param core - the machine being served.
   * @param options - version and reporting hooks.
   */
  constructor(private readonly core: BridleCore, private readonly options: RelayClientOptions) {}

  /** Current connection state. */
  get connectionState(): RelayState {
    return this.state
  }

  /** Number of phones currently attached through the Relay. */
  get attachedCircuits(): number {
    return this.circuits.size
  }

  /** Begin dialing and keep the socket up until {@link RelayClient.stop}. */
  start(): void {
    void this.loop()
  }

  /** Close the Relay socket and every tunnel on it. */
  stop(): void {
    this.unwatchWaiting?.()
    this.unwatchWaiting = undefined
    this.abort.abort()
    this.teardown('bridle is shutting down')
    this.socket?.close()
  }

  private async loop(): Promise<void> {
    this.unwatchWaiting ??= this.core.onWaitingChanged(() => { this.ringSleepers() })
    while (!this.abort.signal.aborted) {
      this.publish('connecting')
      const reason = await this.connectOnce()
      if (this.abort.signal.aborted) return
      // The reset is earned by staying up, not by registering — see STABLE_MS.
      if (this.onlineAt !== undefined && Date.now() - this.onlineAt >= (this.options.stableMs ?? STABLE_MS)) this.retry = RETRY_MIN_MS
      this.onlineAt = undefined
      this.publish('offline', reason)
      const wait = this.retry + Math.floor(Math.random() * this.retry * 0.3)
      this.options.log?.(`relay disconnected (${reason}); retrying in ${String(Math.round(wait / 1000))}s`)
      await sleep(wait, this.abort.signal)
      this.retry = Math.min(this.retry * 2, RETRY_MAX_MS)
    }
  }

  private connectOnce(): Promise<string> {
    return new Promise((resolve) => {
      const url = new URL('/v1/bridle', toWebSocketUrl(this.core.state.relayUrl))
      const socket = new WebSocket(url)
      this.socket = socket
      let registered = false
      let settled = false
      const settle = (reason: string): void => {
        if (settled) return
        settled = true
        this.registered = false
        clearTimeout(registerTimer)
        if (this.keepalive !== undefined) clearInterval(this.keepalive)
        this.abort.signal.removeEventListener('abort', onAbort)
        this.teardown(reason)
        try {
          socket.close()
        } catch {
          // Already closing; nothing further to do.
        }
        resolve(reason)
      }
      const onAbort = (): void => { settle('stopped') }
      this.abort.signal.addEventListener('abort', onAbort, { once: true })
      const registerTimer = setTimeout(() => {
        if (!registered) settle('relay did not complete registration')
      }, REGISTER_TIMEOUT_MS)

      // Any inbound byte counts, control frames included: the question is
      // whether this socket still carries traffic, not what the traffic said.
      let lastHeard = Date.now()
      const heard = (): void => { lastHeard = Date.now() }

      socket.on('open', () => {
        heard()
        const every = this.options.keepaliveMs ?? KEEPALIVE_MS
        const limit = this.options.silenceMs ?? SILENCE_LIMIT_MS
        this.keepalive = setInterval(() => {
          const silence = Date.now() - lastHeard
          if (silence > limit) {
            // `terminate`, not `close`: a close frame to a dead flow waits for
            // a reply that is never coming, and the point of noticing is to
            // redial now.
            socket.terminate()
            settle(`relay went quiet for ${String(Math.round(silence / 1000))}s`)
            return
          }
          socket.ping()
        }, every)
        this.keepalive.unref()
      })

      socket.on('pong', heard)
      socket.on('ping', heard)

      socket.on('message', (data: WebSocket.RawData, isBinary: boolean) => {
        heard()
        if (!isBinary) {
          const control = parseControl(data)
          if (control === undefined) return
          if (control.t === 'challenge' && control.nonce !== undefined) {
            socket.send(JSON.stringify(this.registration(control.nonce)))
            return
          }
          if (control.t === 'registered') {
            registered = true
            this.registered = true
            this.onlineAt = Date.now()
            this.publish('online')
            this.options.log?.(`relay online as ${this.core.state.deviceId}`)
            // Anything that stopped the agent while the Relay was down is owed
            // a ring, and this is the first moment one can be sent.
            this.flushWake()
            return
          }
          settle(control.message ?? 'relay refused the connection')
          return
        }
        if (!registered) {
          settle('relay sent data before registration')
          return
        }
        this.onMux(toBuffer(data))
      })

      socket.on('error', (error: Error) => { settle(error.message) })
      socket.on('close', (code: number, reason: Buffer) => {
        settle(reason.length > 0 ? reason.toString() : `relay closed the socket (${String(code)})`)
      })
    })
  }

  private registration(nonce: string): Record<string, string> {
    const keys = signingKeys(this.core.state)
    return {
      t: 'register',
      device: deviceIdFor(keys.publicKey),
      key: keys.publicKey.toString('base64url'),
      signature: signRegistration(keys.privateKey, nonce),
      name: this.core.state.machineName,
      bridle: this.options.version,
    }
  }

  private onMux(bytes: Buffer): void {
    let message
    try {
      message = decodeMux(bytes)
    } catch (error) {
      this.options.log?.(`ignoring malformed relay frame: ${error instanceof Error ? error.message : String(error)}`)
      return
    }
    const socket = this.socket
    if (socket === undefined) return
    switch (message.type) {
      case MuxType.Open: {
        this.circuits.get(message.circuit)?.dispose('circuit reopened')
        const session = new TunnelSession(this.core, {
          send: (payload: Buffer) => { socket.send(encodeMux(MuxType.Data, message.circuit, payload)) },
          close: (reason: string) => {
            if (this.circuits.delete(message.circuit) && socket.readyState === WebSocket.OPEN) {
              socket.send(encodeMux(MuxType.Close, message.circuit, Buffer.from(reason, 'utf8')))
            }
          },
        }, {
          version: this.options.version,
          onAuthenticated: (_key, name) => { this.options.log?.(`${name} attached over the relay`) },
        })
        this.circuits.set(message.circuit, session)
        return
      }
      case MuxType.Data:
        this.circuits.get(message.circuit)?.receive(message.payload)
        return
      case MuxType.Close: {
        const session = this.circuits.get(message.circuit)
        this.circuits.delete(message.circuit)
        session?.dispose(message.payload.length > 0 ? message.payload.toString('utf8') : 'phone disconnected')
        return
      }
      case MuxType.Wake:
        this.forgetDeadToken(message.payload)
        return
      default:
        return
    }
  }

  /**
   * Ring every paired phone, because none of them is listening.
   *
   * The condition is deliberately the crude one — nobody attached, over either
   * transport — rather than anything cleverer about which phone belongs to
   * whom. A machine is paired with a handful of devices at most, all of them
   * the same person's, and the alternative is guessing which pocket they are
   * in. Ringing a phone whose owner is already looking at another one costs a
   * banner; guessing wrong costs the notification the feature exists for.
   */
  private ringSleepers(): void {
    this.flushWake()
  }

  /**
   * Send any wake that is owed, if the Relay can take it.
   *
   * Gated on `registered`, not merely on the socket being open. A binary frame
   * that arrives before the registration handshake completes is not ignored by
   * the Relay — it closes the connection with `data before registration`, so
   * ringing a phone during that window would knock the machine off the Relay
   * entirely.
   */
  private flushWake(): void {
    const socket = this.socket
    if (!this.registered || socket === undefined || socket.readyState !== WebSocket.OPEN) return
    // Asked of the core rather than remembered from the moment the agent
    // stopped, because a remembered answer and the truth drift apart in both
    // directions.
    //
    // A boolean set when the agent stopped was wrong twice. It was never set at
    // all if somebody happened to be attached at that instant — so a question
    // asked while you were looking at your phone, and left unanswered when you
    // put it down, rang nobody, ever. And it stayed set through a Relay outage
    // even if the question was answered in the browser meanwhile, so the Relay
    // coming back produced a notification about something already dealt with.
    //
    // The fact it was copying already exists and is kept current: the core's
    // pending list, which `approval/resolved` and `question/resolved` remove
    // from. Deriving costs a property read.
    if (this.core.attached > 0) return
    if (this.core.pendingRequests.length === 0) return
    // By endpoint, not by peer. One phone can hold two pairings — `bridle
    // revoke` is manual and a phone that re-pairs after a reset arrives with a
    // fresh device identity but the same APNs token — and ringing per peer
    // would then buzz it twice for one question.
    const rung = new Set<string>()
    for (const peer of this.core.state.peers) {
      if (peer.push === undefined || rung.has(peer.push)) continue
      rung.add(peer.push)
      socket.send(encodeMux(MuxType.Wake, 0, Buffer.from(JSON.stringify({
        token: peer.push,
        machine: this.core.state.machineName,
      }), 'utf8')))
    }
  }

  /**
   * Stop ringing a number that no longer exists.
   *
   * APNs answers `BadDeviceToken` for an app that was uninstalled, or restored
   * onto a different phone, and the Relay passes that back because this is the
   * only process that holds the token. Without it a revoked device would be
   * rung on every request for as long as the pairing lasted.
   * @param payload - the Relay's JSON reply.
   */
  private forgetDeadToken(payload: Buffer): void {
    let token: unknown
    let dead: unknown
    try {
      ({ token, dead } = JSON.parse(payload.toString('utf8')) as { token?: unknown; dead?: unknown })
    } catch {
      return
    }
    // Both fields, not just the address. The Relay sends this shape to say one
    // specific thing — Apple reports the device gone — and a later Relay that
    // learns to say something else about a token over the same message type
    // would otherwise be read as a deletion order by every Bridle already
    // deployed. Requiring the claim to be made explicitly is what lets that
    // message type grow.
    if (typeof token !== 'string' || dead !== true) return
    let changed = false
    for (const peer of this.core.state.peers) {
      if (peer.push !== token) continue
      delete peer.push
      changed = true
    }
    if (!changed) return
    this.options.log?.('a phone stopped accepting notifications; it will be rung again when it reconnects')
    this.core.save()
  }

  private teardown(reason: string): void {
    for (const session of [...this.circuits.values()]) session.dispose(reason)
    this.circuits.clear()
  }

  private publish(state: RelayState, detail?: string): void {
    if (state === this.state) return
    this.state = state
    this.options.onState?.(state, detail)
  }
}

/**
 * Normalize a Relay base URL to a WebSocket scheme.
 * @param base - an `http(s)://` or `ws(s)://` URL.
 * @returns the same origin with a WebSocket scheme.
 */
export function toWebSocketUrl(base: string): string {
  const url = new URL(base)
  if (url.protocol === 'http:') url.protocol = 'ws:'
  else if (url.protocol === 'https:') url.protocol = 'wss:'
  return url.toString()
}

function parseControl(data: WebSocket.RawData): RelayControl | undefined {
  try {
    const parsed: unknown = JSON.parse(toBuffer(data).toString('utf8'))
    if (typeof parsed !== 'object' || parsed === null) return undefined
    return parsed as RelayControl
  } catch {
    return undefined
  }
}

function toBuffer(data: WebSocket.RawData): Buffer {
  if (Buffer.isBuffer(data)) return data
  if (Array.isArray(data)) return Buffer.concat(data)
  return Buffer.from(data)
}

function sleep(ms: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve) => {
    const timer = setTimeout(finish, ms)
    signal.addEventListener('abort', finish, { once: true })
    function finish(): void {
      clearTimeout(timer)
      signal.removeEventListener('abort', finish)
      resolve()
    }
  })
}
