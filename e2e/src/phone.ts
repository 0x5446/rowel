/**
 * A phone, in TypeScript.
 *
 * This is the reference implementation of the app side of the tunnel: the
 * Noise IK handshake and the version-2 frames — unary calls and dsh streams,
 * passed through. `ios/Rowel/Protocol` implements the handshake in Swift and
 * still speaks version 1 until milestone M2 of docs/dsh-0.2-migration.md ports
 * it; until then this file, not the Swift one, is the reference for frames. Keeping it here does two things —
 * it lets the end-to-end tests drive a real Bridle against a real harness with
 * no simulator in the loop, and it gives the Swift code something authoritative
 * to be checked against.
 */

import WebSocket from 'ws'
import {
  NoiseInitiator,
  TUNNEL_PROLOGUE,
  TUNNEL_VERSIONS,
  decodeFrame,
  encodeFrame,
  generateKeyPair,
  type PairingBundle,
  type ReadyFrame,
  type SecureChannel,
  type ServerFrame,
  type StaticKeyPair,
  type FrameError,
} from '@rowel/protocol'

/** The result shape every dsh endpoint answers with. */
export type CallResult =
  | { ok: true; value: unknown }
  | { ok: false; error: FrameError }

/** How a stream finished. */
export type StreamOutcome = { kind: 'end' } | { kind: 'error'; error: FrameError }

/** One dsh stream, as the phone holds it. */
export interface PhoneStream {
  readonly sid: string
  /** Every item received so far, in order. */
  readonly items: unknown[]
  /** Settles once the Bridle ends or fails the stream. Never settles after `cancel`. */
  readonly done: Promise<StreamOutcome>
  /**
   * Watch items as they arrive.
   * @returns a function that stops watching.
   */
  onItem: (listener: (value: unknown) => void) => () => void
  /** Send one uplink item. */
  send: (value: unknown) => void
  /** Half-close the uplink. */
  end: () => void
  /** Stop the stream. */
  cancel: () => void
}

/** Options for {@link RowelPhone}. */
export interface PhoneOptions {
  /** The pairing bundle scanned or claimed. */
  bundle: PairingBundle
  /** This device's long-term key pair; persist it across launches. */
  keys?: StaticKeyPair
  /** Device name shown on the machine's paired list. */
  name?: string
  /** App build string. */
  client?: string
  /** Force one carrier instead of racing them. */
  prefer?: 'direct' | 'relay'
  /** Whether the one-time pairing token should be presented. */
  pairing?: boolean
  /**
   * Versions to offer, overriding this build's own set.
   *
   * Exists so a test can be a client from the future or from the past without
   * checking out a different revision — which is the only way to prove the
   * compatibility window actually holds. `[]` reproduces the oldest clients,
   * which predate negotiation and send no `versions` key at all.
   */
  versions?: number[]
}

/** Thrown when the Bridle refuses the handshake. */
export class HandshakeRefused extends Error {
  /** @param reason - the machine-readable refusal reason. */
  constructor(readonly reason: string) {
    super(`bridle refused the connection: ${reason}`)
    this.name = 'HandshakeRefused'
  }
}

let requestCounter = 0
let streamCounter = 0

/** An app-side tunnel to one Bridle. */
export class RowelPhone {
  readonly keys: StaticKeyPair
  private socket: WebSocket | undefined
  private channel: SecureChannel | undefined
  private readonly pending = new Map<string, (result: CallResult) => void>()
  private readonly streams = new Map<string, {
    items: unknown[]
    listeners: Set<(value: unknown) => void>
    settle: (outcome: StreamOutcome) => void
  }>()
  private ready: ReadyFrame | undefined

  /** @param options - the pairing bundle and this device's identity. */
  constructor(private readonly options: PhoneOptions) {
    this.keys = options.keys ?? generateKeyPair()
  }

  /** The `ready` frame from the last successful connection. */
  get readyFrame(): ReadyFrame | undefined {
    return this.ready
  }

  /**
   * Dial the machine and complete the handshake.
   * @returns the `ready` frame the Bridle sends first.
   * @throws {@link HandshakeRefused} when the machine will not accept this device.
   */
  async connect(): Promise<ReadyFrame> {
    const socket = await this.dial()
    this.socket = socket
    const initiator = new NoiseInitiator(this.keys, Buffer.from(this.options.bundle.key, 'base64url'), TUNNEL_PROLOGUE)
    const offered = this.options.versions ?? [...TUNNEL_VERSIONS]
    const payload = {
      // An empty override means "behave like a client that predates
      // negotiation": omit the key entirely rather than sending an empty list.
      ...(offered.length === 0 ? {} : { versions: offered }),
      name: this.options.name ?? 'iPhone',
      client: this.options.client ?? 'rowel-reference/0.1.0',
      ...(this.options.pairing === false ? {} : { token: this.options.bundle.token }),
    }

    return new Promise<ReadyFrame>((resolve, reject) => {
      const timer = setTimeout(() => { reject(new Error('bridle did not send a ready frame')) }, 15_000)
      const fail = (error: Error): void => {
        clearTimeout(timer)
        reject(error)
      }
      this.onReady = (frame: ReadyFrame): void => {
        clearTimeout(timer)
        resolve(frame)
      }

      // The listener goes on before the first byte leaves. The Bridle answers
      // the handshake and sends `ready` back to back, and a WebSocket receiver
      // can emit both from one read — an await in between would drop the
      // second. The Swift client has to be written the same way.
      let handshakeDone = false
      socket.on('message', (data: WebSocket.RawData) => {
        const bytes = toBuffer(data)
        if (handshakeDone) {
          this.onMessage(bytes)
          return
        }
        handshakeDone = true
        try {
          const reply = initiator.readMessage(bytes)
          const parsed = JSON.parse(reply.payload.toString('utf8')) as { ok?: boolean; reason?: string }
          if (parsed.ok !== true) throw new HandshakeRefused(parsed.reason ?? 'unknown')
          this.channel = reply.channel
        } catch (error) {
          socket.close()
          fail(error instanceof Error ? error : new Error(String(error)))
        }
      })
      socket.on('close', () => {
        this.failAll('connection closed')
        fail(new Error('the machine closed the connection before it was ready'))
      })

      socket.send(initiator.writeMessage(Buffer.from(JSON.stringify(payload), 'utf8')), { binary: true })
    })
  }

  private onReady: ((frame: ReadyFrame) => void) | undefined

  /**
   * Invoke one dsh endpoint.
   * @param endpoint - e.g. `session/list`.
   * @param args - the endpoint's arguments, with exactly the names dsh declares.
   * @returns the dsh result.
   */
  call(endpoint: string, args: unknown = {}): Promise<CallResult> {
    const id = this.callId()
    return new Promise((resolve) => {
      this.pending.set(id, resolve)
      this.send({ t: 'call', id, endpoint, args })
    })
  }

  /**
   * Invoke one dsh endpoint, keeping the id so the call can be abandoned.
   * @param endpoint - e.g. `session/list`.
   * @param args - the endpoint's arguments.
   * @returns the id and the eventual result.
   */
  callAbortable(endpoint: string, args: unknown = {}): { id: string; result: Promise<CallResult> } {
    const id = this.callId()
    const result = new Promise<CallResult>((resolve) => {
      this.pending.set(id, resolve)
      this.send({ t: 'call', id, endpoint, args })
    })
    return { id, result }
  }

  /**
   * Abandon an in-flight call.
   * @param id - the call id.
   */
  abort(id: string): void {
    this.send({ t: 'abort', id })
  }

  /**
   * Open a dsh stream through the Bridle.
   * @param endpoint - e.g. `session/follow`, or `$events`.
   * @param args - the endpoint's arguments.
   * @returns the stream.
   */
  open(endpoint: string, args: unknown = {}): PhoneStream {
    streamCounter += 1
    const sid = `s${String(streamCounter)}`
    const items: unknown[] = []
    const listeners = new Set<(value: unknown) => void>()
    let settle: (outcome: StreamOutcome) => void = () => {}
    const done = new Promise<StreamOutcome>((resolve) => { settle = resolve })
    this.streams.set(sid, { items, listeners, settle })
    this.send({ t: 'open', sid, endpoint, args })
    return {
      sid,
      items,
      done,
      onItem: (listener) => {
        listeners.add(listener)
        return (): void => { listeners.delete(listener) }
      },
      send: (value) => { this.send({ t: 'item', sid, value }) },
      end: () => { this.send({ t: 'end', sid }) },
      cancel: () => {
        this.streams.delete(sid)
        this.send({ t: 'cancel', sid })
      },
    }
  }

  /**
   * Answer an approval or a question that arrived on this phone's `$events`.
   *
   * The part a client has to get right: dsh routes the answer by the
   * `clientId` its own `$events` stream was given in its `ready` item, and the
   * `eventId` of the waterfall being answered. The first answer from any
   * client wins; a late one is accepted and changes nothing.
   * @param clientId - from the `ready` item of this phone's `$events` stream.
   * @param eventId - from the waterfall item being answered.
   * @param value - the answer: `'allowed-once'` / `'rejected'`, or `{ answers }`.
   * @returns dsh's receipt.
   */
  answer(clientId: string, eventId: string, value: unknown): Promise<CallResult> {
    return this.call('$events/result', { clientId, eventId, outcome: { kind: 'result', value } })
  }

  /**
   * Offer, or withdraw, somewhere to be rung when this phone is not attached.
   * @param token - the APNs device token, or null to stop being rung.
   */
  wake(token: string | null): void {
    this.send({ t: 'wake', token })
  }

  /** Close the tunnel. */
  close(): void {
    this.failAll('closed by the app')
    this.socket?.close()
    this.socket = undefined
    this.channel = undefined
  }

  private async dial(): Promise<WebSocket> {
    const candidates: string[] = []
    if (this.options.prefer !== 'relay') for (const address of this.options.bundle.direct ?? []) candidates.push(`${address}/v1/tunnel`)
    if (this.options.prefer !== 'direct') {
      const relay = new URL('/v1/app', toWebSocket(this.options.bundle.relay))
      relay.searchParams.set('device', this.options.bundle.device)
      candidates.push(relay.toString())
    }
    const failures: string[] = []
    for (const candidate of candidates) {
      try {
        return await open(candidate)
      } catch (error) {
        // Trying the LAN address first costs one failed connect when the phone
        // is elsewhere, which is cheaper than always paying for the round trip.
        failures.push(`${candidate}: ${error instanceof Error ? error.message : String(error)}`)
      }
    }
    throw new Error(`could not reach the machine (${failures.join('; ')})`)
  }

  private onMessage(bytes: Buffer): void {
    const channel = this.channel
    if (channel === undefined) return
    const frame = decodeFrame(channel.decrypt(bytes)) as ServerFrame
    switch (frame.t) {
      case 'ready':
        this.ready = frame
        this.onReady?.(frame)
        this.onReady = undefined
        return
      case 'result': {
        const resolve = this.pending.get(frame.id)
        this.pending.delete(frame.id)
        resolve?.(frame.result)
        return
      }
      case 'item': {
        const stream = this.streams.get(frame.sid)
        if (stream === undefined) return
        stream.items.push(frame.value)
        for (const listener of stream.listeners) listener(frame.value)
        return
      }
      case 'end':
      case 'error': {
        const stream = this.streams.get(frame.sid)
        this.streams.delete(frame.sid)
        stream?.settle(frame.t === 'end' ? { kind: 'end' } : { kind: 'error', error: frame.error })
        return
      }
      case 'ping':
        this.send({ t: 'pong', nonce: frame.nonce })
        return
      default:
        return
    }
  }

  private send(frame: Parameters<typeof encodeFrame>[0]): void {
    const channel = this.channel
    const socket = this.socket
    if (channel === undefined || socket === undefined) throw new Error('tunnel is not connected')
    socket.send(channel.encrypt(encodeFrame(frame)), { binary: true })
  }

  private failAll(reason: string): void {
    for (const [, resolve] of this.pending) {
      resolve({ ok: false, error: { code: 'disconnected', message: reason, details: {} } })
    }
    this.pending.clear()
    for (const stream of this.streams.values()) {
      stream.settle({ kind: 'error', error: { code: 'disconnected', message: reason, details: {} } })
    }
    this.streams.clear()
  }

  private callId(): string {
    requestCounter += 1
    return `p${String(requestCounter)}`
  }
}

function toWebSocket(base: string): string {
  const url = new URL(base)
  if (url.protocol === 'http:') url.protocol = 'ws:'
  else if (url.protocol === 'https:') url.protocol = 'wss:'
  return url.toString()
}

function open(address: string): Promise<WebSocket> {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(address, { handshakeTimeout: 4_000 })
    socket.once('open', () => {
      socket.removeAllListeners('error')
      socket.removeAllListeners('close')
      resolve(socket)
    })
    socket.once('error', reject)
    socket.once('close', (code: number, reason: Buffer) => {
      reject(new Error(reason.length > 0 ? reason.toString() : `closed with ${String(code)}`))
    })
  })
}

function toBuffer(data: WebSocket.RawData): Buffer {
  if (Buffer.isBuffer(data)) return data
  if (Array.isArray(data)) return Buffer.concat(data)
  return Buffer.from(data)
}
