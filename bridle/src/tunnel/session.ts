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
  type ClientFrame,
  type SecureChannel,
  type ServerFrame,
  MAX_FRAME_BYTES,
} from '@rowel/protocol'
import { findPeer, redeemOffer, rowelHome, touchPeer, updateState } from '../identity.ts'
import type { BridleCore, DshStatus } from '../core.ts'
import type { LoggedEvent } from './event-log.ts'
import { thinHistory } from './history.ts'
import { thinRoster } from './roster.ts'
import type { AgentResult } from '../agents/types.ts'

/**
 * What to ask dsh for when the caller named no page size.
 *
 * dsh's own default is 50. This is only the starting point for the shrink
 * loop below — the app states its own, and the loop lowers whatever it gets.
 */
const DEFAULT_HISTORY_MESSAGES = 25

/** The carrier a session writes through. */
export interface TunnelTransport {
  /** Deliver one carrier message. */
  send: (bytes: Buffer) => void
  /** Tear the carrier down. */
  close: (reason: string) => void
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

/** Concurrent dsh calls one phone may have outstanding. */
const MAX_INFLIGHT = 64

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
  private unsubscribe: (() => void) | undefined
  private detach: (() => void) | undefined
  private unwatchStatus: (() => void) | undefined
  private pingTimer: NodeJS.Timeout | undefined
  /** When anything last arrived from the peer. */
  private heardAt = Date.now()
  private lastSent = 0
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
    this.unsubscribe?.()
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
    const name = typeof request.name === 'string' && request.name.length > 0 ? request.name : 'iPhone'
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
      // Which harness this identity fronts, and where the identity lives on
      // disk. One machine can run several Bridles, and until the app knows
      // which one it is talking to, every offline screen says the same name
      // and every rescue command defaults to the wrong home. Nothing here is
      // a new disclosure: a paired peer can already call `host.describe`
      // through this same channel and read cwd and home from the harness.
      harness: { url: this.core.state.dshUrl, home: rowelHome() },
      ...(status.host === undefined ? {} : { host: status.host }),
      // Where this machine can be dialled directly *now*, so the app can
      // retire the addresses frozen into its pairing bundle. Sent even when
      // empty: an empty list is the truth about a machine whose direct
      // listener is off, and withholding it would leave the app dialling a
      // listener that no longer exists.
      direct: this.core.directAddresses(),
      seq: this.core.events.head,
      epoch: this.core.events.epoch,
    })
    // Whatever the machine is already waiting on, said before anything else.
    //
    // Sent at sequence zero on purpose: these are not a position in the event
    // log but a statement of what is true now, and a real sequence here would
    // move the app's resume point past events it has not been given yet. The
    // app folds them exactly as it folds the live ones, and being told twice
    // is harmless — the card is keyed by session, not appended to a list.
    for (const request of this.core.pendingRequests) {
      this.sendFrame({ t: 'ev', seq: 0, stream: 'mux', frame: request })
    }
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
      case 'req':
        void this.handleRequest(frame.id, frame.method, frame.payload)
        return
      case 'cancel':
        this.inflight.get(frame.id)?.abort()
        this.inflight.delete(frame.id)
        return
      case 'respond':
        void this.handleRespond(frame.id, frame.message)
        return
      case 'resume':
        this.handleResume(frame.since, frame.epoch)
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

  private handleResume(since: number, epoch?: string): void {
    this.unsubscribe?.()
    const result = this.core.events.replay(since, epoch)
    if (result.kind === 'resync') {
      this.lastSent = result.from
      this.sendFrame({ t: 'resync', from: result.from })
    } else {
      this.lastSent = since
      for (const event of result.events) this.emit(event)
    }
    // Subscribing in the same synchronous tick as the replay is what makes this
    // gapless: no append can land between the two.
    this.unsubscribe = this.core.events.subscribe((event: LoggedEvent) => { this.emit(event) })
  }

  private emit(event: LoggedEvent): void {
    if (event.seq <= this.lastSent) return
    this.lastSent = event.seq
    this.sendFrame({ t: 'ev', seq: event.seq, stream: event.stream, frame: event.frame })
  }

  private async handleRequest(id: string, method: string, payload: unknown): Promise<void> {
    if (this.inflight.size >= MAX_INFLIGHT) {
      this.sendFrame({
        t: 'res',
        id,
        result: { ok: false, error: { code: 'busy', message: `more than ${String(MAX_INFLIGHT)} calls in flight`, details: {} } },
      })
      return
    }
    const controller = new AbortController()
    this.inflight.set(id, controller)
    try {
      const result = method === 'session.history'
        ? await this.historyThatFits(payload, controller.signal)
        : method === 'session.export'
          ? await this.exportSession(payload)
          : method === 'session.list'
            ? this.trimRoster(await this.core.dsh.call(method, payload, controller.signal))
            : await this.core.dsh.call(method, payload, controller.signal)
      if (!this.closed) this.sendFrame({ t: 'res', id, result })
    } finally {
      this.inflight.delete(id)
    }
  }

  /**
   * Drop the list projections the app does not read.
   * @param result - whatever dsh answered `session.list` with.
   * @returns the same result, lighter.
   */
  private trimRoster(result: AgentResult): AgentResult {
    if (!result.ok) return result
    const { value, trimming } = thinRoster(result.value)
    if (trimming !== undefined) {
      this.options.log?.(`session.list ${String(trimming.before)} to ${String(trimming.after)} bytes`)
    }
    return { ok: true, value }
  }

  private async exportSession(payload: unknown): Promise<{ ok: true; value: unknown } | { ok: false; error: { code: string; message: string; details: unknown } }> {
    const request = payload as { sessionId?: unknown; includeDescendants?: unknown }
    if (typeof request.sessionId !== 'string') {
      return { ok: false, error: { code: 'bad-request', message: 'session.export needs a sessionId', details: {} } }
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

  private async handleRespond(id: string, message: unknown): Promise<void> {
    try {
      const receipt = await this.core.dsh.respond(message)
      this.sendFrame({ t: 'res', id, result: { ok: true, value: receipt } })
    } catch (error) {
      this.sendFrame({
        t: 'res',
        id,
        result: { ok: false, error: { code: 'internal', message: error instanceof Error ? error.message : String(error), details: {} } },
      })
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
   * Fetch a history page small enough to send, halving the ask until it fits.
   *
   * A page is bounded by *messages*, and dsh is explicit that each one stays
   * one contiguous raw event range — so a single message can span tens of
   * thousands of `assistant/chunk` events and the byte size of a page has no
   * ceiling at all. This is not hypothetical: a 25-message page came back as
   * 22 MB. `thinHistory` handles the usual shape of that by dropping chunks
   * that a committed message has already superseded, but a page still
   * streaming has nothing to drop.
   *
   * So when the thinned page is still too big, ask for fewer messages. That is
   * not a workaround — smaller pages are what `maxMessages` is *for*, and the
   * caller already knows how to follow `hasMore`. It gets a shorter page and
   * carries on, instead of an error about a limit it did not set and cannot do
   * anything about.
   *
   * Only history, because only history has a size knob. `session.export` takes
   * no page argument and `session.list` returns what it returns; for those the
   * ceiling check in `sendFrame` is the whole answer.
   */
  private async historyThatFits(payload: unknown, signal: AbortSignal): Promise<AgentResult> {
    const request = (payload ?? {}) as Record<string, unknown>
    const asked = typeof request['maxMessages'] === 'number' ? request['maxMessages'] : DEFAULT_HISTORY_MESSAGES
    let messages = Math.max(1, Math.floor(asked))

    for (;;) {
      const attempt = await this.core.dsh.call(
        'session.history',
        { ...request, maxMessages: messages },
        signal,
      )
      if (!attempt.ok) return attempt

      const { value, thinning } = thinHistory(attempt.value)
      if (thinning !== undefined) {
        this.options.log?.(`history thinned ${String(thinning.before)} → ${String(thinning.after)} events`)
      }
      const result: AgentResult = { ok: true, value }

      const size = encodeFrame({ t: 'res', id: 'sizing', result }).length
      // One message that still does not fit is the end of the line: there is
      // nothing smaller to ask for. Send it and let `sendFrame` turn it into an
      // error the caller can read, rather than looping forever.
      if (size <= MAX_FRAME_BYTES || messages === 1) return result

      const smaller = Math.max(1, Math.floor(messages / 2))
      this.options.log?.(
        `history page was ${(size / (1024 * 1024)).toFixed(1)} MB at ${String(messages)} messages; retrying with ${String(smaller)}`,
      )
      messages = smaller
    }
  }

  /**
   * Deal with a frame nobody on the path will carry.
   *
   * Writing it anyway is the worst option available: the relay closes the
   * connection with a 1009 before the app sees a byte, the app reconnects and
   * resumes, the same call is answered with the same oversized frame, and the
   * tunnel drops again — forever, with no error anywhere that names the cause.
   * The observed shape of this is a `session.history` page that came back as
   * 22 MB of streaming chunks; `thinHistory` keeps that one under the ceiling
   * now, but `session.export` has no such guard and a long session's archive
   * has no upper bound at all.
   *
   * A response can fail on its own, so it does. An event cannot — there is no
   * request waiting on it — so it is dropped, which loses one frame instead of
   * the connection, and the app is told to refetch. It cannot notice the gap
   * itself: if the dropped event was the last one, no later sequence arrives.
   */
  private sendOversize(frame: ServerFrame, size: number): void {
    const megabytes = (size / (1024 * 1024)).toFixed(1)
    const ceiling = (MAX_FRAME_BYTES / (1024 * 1024)).toFixed(0)
    this.options.log?.(`dropping a ${megabytes} MB ${frame.t} frame; the ceiling is ${ceiling} MB`)
    if (frame.t === 'ev') {
      // Not for the `seq: 0` snapshot of pending requests: it is not a position
      // in the log, and `from: 0` would throw away the app's resume point.
      if (frame.seq > 0) this.sendFrame({ t: 'resync', from: frame.seq })
      return
    }
    if (frame.t !== 'res') return
    this.sendFrame({
      t: 'res',
      id: frame.id,
      result: {
        ok: false,
        error: {
          code: 'too-large',
          message: `That answer is ${megabytes} MB, over the ${ceiling} MB the tunnel can carry in one piece.`,
          details: { bytes: size, limit: MAX_FRAME_BYTES },
        },
      },
    })
  }
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
