/**
 * One phone's connection to one Bridle: the Noise responder handshake, then the
 * tunnel frame loop.
 *
 * The carrier underneath is deliberately dumb — a Relay WebSocket, a LAN
 * WebSocket, or a pair of in-memory queues in the tests. Everything that
 * matters to security and to correctness happens here.
 */

import {
  NoiseError,
  NoiseResponder,
  TUNNEL_PROLOGUE,
  TUNNEL_VERSION,
  TUNNEL_VERSIONS,
  negotiateVersion,
  decodeFrame,
  encodeFrame,
  type CallResult,
  type ClientFrame,
  type SecureChannel,
  type ServerFrame,
  MAX_FRAME_BYTES,
} from '@rowel/protocol'
import { homedir } from 'node:os'
import { findPeer, redeemOffer, rowelHome, touchPeer, updateState } from '../identity.ts'
import type { BridleCore, DshStatus } from '../core.ts'
import type { StreamHandle } from '../agents/types.ts'

/** The carrier a session writes through. */
export interface TunnelTransport {
  /** Deliver one carrier message. */
  send: (bytes: Buffer) => void
  /** Tear the carrier down. */
  close: (reason: string) => void
  /**
   * Bytes written but not yet handed to the network, when the carrier can say.
   * dsh does not slow down for a slow reader, so this is where a phone that
   * cannot keep up shows.
   */
  buffered?: () => number
}

/** What the app states in the handshake payload. */
interface HandshakeRequest {
  /** Versions the app can speak, preferred first. Absent means the pre-negotiation client, i.e. `[1]`. */
  versions?: number[]
  /** One-time pairing token; required only for a device that is not yet paired. */
  token?: string
  /** Device name, shown in `bridle status` and the revoke list. */
  name?: string
  /** App build string. */
  client?: string
}

/** What the Bridle states back inside handshake message two. */
interface HandshakeReply {
  ok: boolean
  /** The version both ends will speak. Present when `ok`. */
  version?: number
  /**
   * Refusal reason when `ok` is false. `pending` is not final: the device
   * presented the short-code token and waits for a person at the Mac.
   */
  reason?: 'version' | 'unpaired' | 'internal' | 'pending'
  /** What this build can speak. Present when refusing for `version`, so the app can say which end is old. */
  supported?: number[]
  /** Human-readable machine name. */
  machine?: string
  /** Bridle package version. */
  bridle?: string
}

/** Longest device name kept, in characters. */
const MAX_DEVICE_NAME = 64

/**
 * The name a device reported, made safe to store and to print on the Mac.
 *
 * Before any trust is established the name comes from whoever holds a token —
 * for the short code, possibly the Relay — and `bridle pair --code` prints it
 * right beside the fingerprint a person compares. With control characters in
 * it, a name could draw a fake fingerprint line and hide the real one. So it
 * loses every control and format character (`\p{C}`: escapes, newlines,
 * bidi overrides, zero-width marks) and is cut to a bounded length.
 * @param raw - the `name` field of the handshake payload.
 * @returns a printable one-line name; `iPhone` when nothing is left.
 */
export function deviceName(raw: unknown): string {
  if (typeof raw !== 'string') return 'iPhone'
  const cleaned = Array.from(raw.replace(/\p{C}/gu, '').trim()).slice(0, MAX_DEVICE_NAME).join('').trim()
  return cleaned.length > 0 ? cleaned : 'iPhone'
}

/** Concurrent dsh calls one phone may have outstanding. */
const MAX_INFLIGHT = 64

/** Streams one phone may have open at once. */
const MAX_STREAMS = 64

/**
 * How far behind a phone may fall before its streams are cut, in bytes. dsh
 * writes as fast as it produces and never waits for a reader; past this, the
 * stream being written to is cancelled with a `slow-consumer` error the app can
 * recover from by reopening it, instead of the Bridle holding an ever-growing
 * buffer for a phone on a bad connection.
 */
const MAX_BUFFERED_BYTES = 8 * 1024 * 1024

/**
 * The one endpoint the Bridle answers itself: dsh serves a session archive as
 * a plain download (`GET /api/session.export`), not as an endpoint a call can
 * reach, so the Bridle fetches it and hands it over base64.
 */
const EXPORT_ENDPOINT = '$export'

/** Tunnel-level liveness probe interval. */
const PING_INTERVAL_MS = 25_000

/** Silence after which the peer is taken to be gone: two missed pings, with slack. */
const PEER_SILENCE_MS = PING_INTERVAL_MS * 2.5

/** Version reported to the app; injected so the CLI and tests agree. */
export interface SessionOptions {
  /** Bridle package version string. */
  version: string
  /** Called once the peer is authenticated. */
  onAuthenticated?: (peerKey: Buffer, name: string) => void
  /** Called when the session ends, for any reason. */
  onClosed?: (reason: string) => void
  /** Progress reporting; quiet when absent. */
  log?: (message: string) => void
}

/** A single authenticated tunnel. */
export class TunnelSession {
  private readonly responder: NoiseResponder
  private channel: SecureChannel | undefined
  private readonly inflight = new Map<string, AbortController>()
  /** The streams this phone opened, by the id it chose. */
  private readonly streams = new Map<string, StreamHandle>()
  private detach: (() => void) | undefined
  private unwatchStatus: (() => void) | undefined
  private pingTimer: NodeJS.Timeout | undefined
  /** When anything last arrived from the peer. */
  private heardAt = Date.now()
  private closed = false
  /** The version this session negotiated. Set once, at handshake. */
  private version = TUNNEL_VERSION

  /**
   * @param core - the machine this tunnel is attached to.
   * @param transport - the carrier.
   * @param options - version string and lifecycle hooks.
   */
  constructor(
    private readonly core: BridleCore,
    private readonly transport: TunnelTransport,
    private readonly options: SessionOptions,
  ) {
    this.responder = new NoiseResponder(core.keys, TUNNEL_PROLOGUE)
  }

  /** The authenticated peer's static public key, once the handshake completes. */
  get peerKey(): Buffer | undefined {
    return this.channel?.remoteStatic
  }

  /**
   * Feed one carrier message.
   * @param bytes - the raw message, exactly as it arrived.
   */
  receive(bytes: Buffer): void {
    if (this.closed) return
    this.heardAt = Date.now()
    try {
      if (this.channel === undefined) this.handleHandshake(bytes)
      else this.handleFrame(decodeFrame(this.channel.decrypt(bytes)))
    } catch (error) {
      // Any failure before the channel exists, or any authentication failure
      // after it, means this carrier cannot be trusted to carry anything else.
      this.dispose(error instanceof NoiseError ? error.message : String(error))
    }
  }

  /**
   * End the session and release everything it holds.
   * @param reason - operator-facing reason, surfaced in logs.
   */
  dispose(reason: string): void {
    if (this.closed) return
    this.closed = true
    for (const controller of this.inflight.values()) controller.abort()
    this.inflight.clear()
    // A phone that went away leaves no stream behind on dsh; it reopens what
    // it needs on its next tunnel and gets a fresh baseline.
    for (const handle of this.streams.values()) handle.cancel()
    this.streams.clear()
    this.unwatchStatus?.()
    if (this.pingTimer !== undefined) clearInterval(this.pingTimer)
    this.detach?.()
    this.transport.close(reason)
    this.options.onClosed?.(reason)
  }

  private handleHandshake(bytes: Buffer): void {
    const { remoteStatic, payload } = this.responder.readMessage(bytes)
    let request: HandshakeRequest = {}
    if (payload.length > 0) {
      try {
        request = JSON.parse(payload.toString('utf8')) as HandshakeRequest
      } catch {
        this.refuse('internal')
        return
      }
    }
    const version = negotiateVersion(request.versions)
    if (version === undefined) {
      // An authenticated refusal, which is the whole point of negotiating in
      // the payload rather than in the prologue: the app can read this, compare
      // `supported` against its own list, and say which end is the old one.
      this.refuse('version', [...TUNNEL_VERSIONS])
      return
    }
    const name = deviceName(request.name)
    // Re-read the file before deciding. `bridle pair` and `bridle revoke` run in
    // a different process, and both have to take effect on the next handshake
    // rather than on the next restart — one grants access, the other removes it.
    this.core.refreshState()
    const known = findPeer(this.core.state, remoteStatic)
    if (known === undefined) {
      const outcome = request.token === undefined ? undefined : redeemOffer(this.core.state, remoteStatic, name, request.token)
      if (outcome === undefined) {
        this.refuse('unpaired')
        return
      }
      if (outcome === 'claimed') {
        // The Relay held the bundle this token came from, so the token says
        // nothing about who is on the other end. A person at the Mac decides.
        this.refuse('pending')
        return
      }
    } else {
      touchPeer(this.core.state, remoteStatic)
    }
    this.version = version
    const reply: HandshakeReply = {
      ok: true,
      version,
      machine: this.core.state.machineName,
      bridle: this.options.version,
    }
    const { message, channel } = this.responder.writeMessage(Buffer.from(JSON.stringify(reply), 'utf8'))
    this.channel = channel
    this.transport.send(message)
    // Counted here, before `afterHandshake` sends anything.
    //
    // It used to be counted at the *end* of `afterHandshake`, which was a slow
    // way to permanently disable push for a machine: `sendFrame` catches a
    // transport failure by calling `dispose()` and then returning normally, so
    // a failed ready frame left `afterHandshake` running to completion — and
    // the attach it then took could never be released, because dispose had
    // already come and gone while `detach` was still undefined. One bad
    // handshake and the core believed a phone was listening forever, which
    // silences every wake from then on.
    this.detach ??= this.core.attach()
    this.options.onAuthenticated?.(remoteStatic, name)
    this.afterHandshake()
  }

  private refuse(reason: NonNullable<HandshakeReply['reason']>, supported?: number[]): void {
    const reply: HandshakeReply = { ok: false, reason, ...(supported === undefined ? {} : { supported }) }
    try {
      const { message } = this.responder.writeMessage(Buffer.from(JSON.stringify(reply), 'utf8'))
      this.transport.send(message)
    } catch {
      // The peer sent something we could not even answer; closing is enough.
    }
    this.dispose(`handshake refused: ${reason}`)
  }

  private afterHandshake(): void {
    if (this.closed) return
    const status = this.core.dshStatus
    this.sendFrame({
      t: 'ready',
      // The negotiated version, not this build's newest. A client that asked
      // for an older one has to be told which one it actually got.
      version: this.version,
      bridle: this.options.version,
      machine: this.core.state.machineName,
      dshReachable: status.reachable,
      ...(status.detail === undefined ? {} : { detail: status.detail }),
      ...(status.version === undefined ? {} : { dsh: status.version }),
      // Which harness this identity fronts, and where the identity lives on
      // disk. One machine can run several Bridles, and until the app knows
      // which one it is talking to, every offline screen says the same name
      // and every rescue command defaults to the wrong home.
      harness: { url: this.core.state.dshUrl, home: rowelHome() },
      // What `host.describe` used to answer and dsh 0.2 no longer does: where
      // the account's home is, for the app's folder picker. A paired peer can
      // already reach the same fact through dsh.
      host: { home: homedir() },
      // Where this machine can be dialled directly *now*, so the app can
      // retire the addresses frozen into its pairing bundle. Sent even when
      // empty: an empty list is the truth about a machine whose direct
      // listener is off.
      direct: this.core.directAddresses(),
    })
    // The ready frame may have failed to send, which disposes the session.
    // Registering listeners and timers on a corpse leaks both.
    if (this.closed) return
    // A `hello` runs this again on a live session; the first round's listener
    // and timer would otherwise outlive it until the process exits.
    this.unwatchStatus?.()
    if (this.pingTimer !== undefined) clearInterval(this.pingTimer)
    this.unwatchStatus = this.core.onDshStatus((next: DshStatus) => {
      this.sendFrame({ t: 'status', dshReachable: next.reachable, ...(next.detail === undefined ? {} : { detail: next.detail }) })
    })
    this.pingTimer = setInterval(() => {
      // A phone that vanished without closing — backgrounded, out of range —
      // leaves a socket nobody reads, and while it stands the core counts a
      // listener and rings nobody. The app answers every ping; two unanswered
      // intervals is a phone that is gone.
      if (Date.now() - this.heardAt > PEER_SILENCE_MS) {
        this.dispose('peer silent')
        return
      }
      this.sendFrame({ t: 'ping', nonce: String(Date.now()) })
    }, PING_INTERVAL_MS)
    this.pingTimer.unref()
  }

  private handleFrame(frame: ClientFrame | ServerFrame): void {
    switch (frame.t) {
      case 'call':
        void this.handleCall(frame.id, frame.endpoint, frame.args)
        return
      case 'abort':
        this.inflight.get(frame.id)?.abort()
        this.inflight.delete(frame.id)
        return
      case 'open':
        this.handleOpen(frame.sid, frame.endpoint, frame.args)
        return
      case 'item':
        this.streams.get(frame.sid)?.item(frame.value)
        return
      case 'end':
        this.streams.get(frame.sid)?.end()
        return
      case 'cancel':
        this.streams.get(frame.sid)?.cancel()
        this.streams.delete(frame.sid)
        return
      case 'wake':
        this.rememberToken(frame.token)
        return
      case 'hello':
        // The handshake payload already carried this; answering with a fresh
        // ready keeps a reconnecting app from having to special-case order.
        this.afterHandshake()
        return
      case 'ping':
        this.sendFrame({ t: 'pong', nonce: frame.nonce })
        return
      case 'pong':
        return
      default:
        // Frames only the Bridle sends, or a newer app's additions. Ignoring an
        // unknown frame is what lets the protocol grow.
        return
    }
  }

  /**
   * Record where this phone can be rung, or stop being able to ring it.
   *
   * Written against the authenticated peer and nothing else: the token arrives
   * inside a channel whose far end has already proved it holds the private key
   * this pairing was made with, so there is no way to register a token for
   * somebody else's phone.
   * @param token - the APNs device token, or null to withdraw.
   */
  private rememberToken(token: string | null): void {
    const key = this.peerKey
    if (key === undefined) return
    const peer = findPeer(this.core.state, key)
    if (peer === undefined || peer.push === (token ?? undefined)) return
    updateState(this.core.state, (disk) => {
      const stored = findPeer(disk, key)
      if (stored === undefined) return
      if (token === null) delete stored.push
      else stored.push = token
    })
  }

  private async handleCall(id: string, endpoint: string, args: unknown): Promise<void> {
    if (this.inflight.size >= MAX_INFLIGHT) {
      this.sendFrame({ t: 'result', id, result: failure('busy', `more than ${String(MAX_INFLIGHT)} calls in flight`) })
      return
    }
    const controller = new AbortController()
    this.inflight.set(id, controller)
    try {
      const result = endpoint === EXPORT_ENDPOINT
        ? await this.exportSession(args)
        : await this.core.dsh.call(endpoint, args, controller.signal)
      if (!this.closed) this.sendFrame({ t: 'result', id, result })
    } finally {
      this.inflight.delete(id)
    }
  }

  /**
   * Open a dsh stream on this phone's behalf and relay it frame for frame.
   *
   * The stream belongs to this tunnel: it is cancelled when the tunnel closes,
   * and only this tunnel hears from it.
   */
  private handleOpen(sid: string, endpoint: string, args: unknown): void {
    if (this.streams.has(sid)) {
      // dsh closes its whole socket for this; here it costs only the stream.
      this.sendFrame({ t: 'error', sid, error: { code: 'bad-request', message: `stream ${sid} is already open`, details: {} } })
      return
    }
    if (this.streams.size >= MAX_STREAMS) {
      this.sendFrame({ t: 'error', sid, error: { code: 'busy', message: `more than ${String(MAX_STREAMS)} streams open`, details: {} } })
      return
    }
    // Registered before dsh is asked, because the first item can arrive while
    // `open` is still running. The entry stands in for the handle until it
    // exists, and a cancel that lands in that window is carried out the
    // moment it does.
    let opened: StreamHandle | undefined
    let cancelledEarly = false
    const entry: StreamHandle = {
      item: (value) => { opened?.item(value) },
      end: () => { opened?.end() },
      cancel: () => {
        if (opened === undefined) cancelledEarly = true
        else opened.cancel()
      },
    }
    this.streams.set(sid, entry)
    opened = this.core.dsh.open(endpoint, args, {
      item: (value) => {
        if (this.streams.get(sid) !== entry) return
        if ((this.transport.buffered?.() ?? 0) > MAX_BUFFERED_BYTES) {
          this.cutStream(sid, 'slow-consumer', 'this phone fell too far behind the stream; reopen it')
          return
        }
        this.sendFrame({ t: 'item', sid, value })
      },
      end: () => {
        if (this.streams.get(sid) !== entry) return
        this.streams.delete(sid)
        this.sendFrame({ t: 'end', sid })
      },
      error: (error) => {
        if (this.streams.get(sid) !== entry) return
        this.streams.delete(sid)
        this.sendFrame({ t: 'error', sid, error })
      },
    })
    if (cancelledEarly) opened.cancel()
  }

  /** Cancel a stream at dsh and tell the phone why. */
  private cutStream(sid: string, code: string, message: string, details: unknown = {}): void {
    const handle = this.streams.get(sid)
    if (handle === undefined) return
    this.streams.delete(sid)
    handle.cancel()
    this.sendFrame({ t: 'error', sid, error: { code, message, details } })
  }

  private async exportSession(args: unknown): Promise<CallResult> {
    const request = (args ?? {}) as { sessionId?: unknown; includeDescendants?: unknown }
    if (typeof request.sessionId !== 'string') {
      return failure('bad-request', `${EXPORT_ENDPOINT} needs a sessionId`)
    }
    const response = await this.core.dsh.export(request.sessionId, request.includeDescendants === true)
    if (!response.ok) {
      return { ok: false, error: { code: 'internal', message: `dsh export answered HTTP ${String(response.status)}`, details: {} } }
    }
    const body = await readUpTo(response, EXPORT_MAX_BYTES)
    if (body === undefined) {
      const ceiling = (MAX_FRAME_BYTES / (1024 * 1024)).toFixed(0)
      return {
        ok: false,
        error: {
          code: 'too-large',
          message: `That archive is too big to send over the tunnel (the limit is ${ceiling} MB once encoded). Export it on the Mac instead.`,
          details: { limit: EXPORT_MAX_BYTES },
        },
      }
    }
    return {
      ok: true,
      value: {
        filename: filenameOf(response.headers.get('content-disposition')) ?? `${request.sessionId}.zip`,
        contentType: response.headers.get('content-type') ?? 'application/zip',
        base64: body.toString('base64'),
      },
    }
  }

  private sendFrame(frame: ServerFrame): void {
    const channel = this.channel
    if (channel === undefined || this.closed) return
    const encoded = encodeFrame(frame)
    if (encoded.length > MAX_FRAME_BYTES) {
      this.sendOversize(frame, encoded.length)
      return
    }
    try {
      this.transport.send(channel.encrypt(encoded))
    } catch (error) {
      this.dispose(error instanceof Error ? error.message : String(error))
    }
  }

  /**
   * Deal with a frame nobody on the path will carry.
   *
   * Writing it anyway is the worst option available: the relay closes the
   * connection with a 1009 before the app sees a byte, the app reconnects,
   * asks again, gets the same oversized frame, and the tunnel drops again —
   * forever, with no error anywhere that names the cause.
   *
   * So the one call or stream responsible fails, and nothing else does: a
   * result becomes a `too-large` failure; a stream item cancels its stream at
   * dsh and the phone hears `too-large` for that stream. (A conversation whose
   * snapshot is too big is reopened by the app with fewer messages.)
   */
  private sendOversize(frame: ServerFrame, size: number): void {
    const megabytes = (size / (1024 * 1024)).toFixed(1)
    const ceiling = (MAX_FRAME_BYTES / (1024 * 1024)).toFixed(0)
    this.options.log?.(`refusing a ${megabytes} MB ${frame.t} frame; the ceiling is ${ceiling} MB`)
    const message = `That is ${megabytes} MB, over the ${ceiling} MB the tunnel can carry in one piece.`
    const details = { bytes: size, limit: MAX_FRAME_BYTES }
    if (frame.t === 'item') {
      this.cutStream(frame.sid, 'too-large', message, details)
      return
    }
    if (frame.t === 'result') {
      this.sendFrame({ t: 'result', id: frame.id, result: { ok: false, error: { code: 'too-large', message, details } } })
    }
  }
}

/** A failure the Bridle makes itself. */
function failure(code: string, message: string): CallResult {
  return { ok: false, error: { code, message, details: {} } }
}

/**
 * Largest archive `session.export` will read: the most that still fits the
 * tunnel's frame ceiling once base64 has grown it by a third, with room for the
 * JSON around it. Checked while reading — the archive used to be read whole,
 * then encoded, then measured, so a long session's export cost three times its
 * size in memory (inside dsh's process, with the plugin) only to be refused.
 */
const EXPORT_MAX_BYTES = Math.floor(MAX_FRAME_BYTES * 3 / 4) - 64 * 1024

/**
 * Read a response body, giving up once it passes `limit` bytes.
 * @param response - the response to read.
 * @param limit - the most bytes to hold.
 * @returns the body, or undefined when it is larger than `limit`.
 */
async function readUpTo(response: Response, limit: number): Promise<Buffer | undefined> {
  const declared = Number(response.headers.get('content-length') ?? Number.NaN)
  if (declared > limit) {
    await response.body?.cancel()
    return undefined
  }
  if (response.body === null) return Buffer.alloc(0)
  const reader = response.body.getReader()
  const chunks: Buffer[] = []
  let held = 0
  for (;;) {
    const { done, value } = await reader.read()
    if (done) return Buffer.concat(chunks, held)
    held += value.byteLength
    if (held > limit) {
      await reader.cancel().catch(() => {})
      return undefined
    }
    chunks.push(Buffer.from(value))
  }
}

function filenameOf(disposition: string | null): string | undefined {
  if (disposition === null) return undefined
  const match = /filename\*?=(?:UTF-8'')?"?([^";]+)"?/iu.exec(disposition)
  return match?.[1]
}
