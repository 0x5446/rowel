/**
 * The one connection a Bridle keeps to dsh's stream endpoint, `/api/remote.mux`.
 *
 * dsh 0.2 carries every stream — a conversation's `session/follow`, the
 * workspace list, the `$events` that bring approvals — as a logical stream on
 * one WebSocket, framed `open` / `item` / `end` / `cancel` from the client and
 * `item` / `end` / `error` back (docs/dsh-0.2-protocol.md §3). Every phone's
 * streams and the Bridle's own share this one socket; the Bridle numbers them
 * itself, so two phones choosing the same stream id never collide.
 *
 * dsh has no resumption at the stream level: a dropped socket ends every
 * stream on it. So does this — each open stream is told it failed with
 * `upstream-lost`, and whoever opened it reopens it on a fresh socket and gets
 * a fresh baseline, which is how dsh's own browser client recovers too.
 */

import WebSocket from 'ws'
import { assertLoopback } from './client.ts'
import { cookieFor, forgetCookie } from './credentials.ts'

/** A stream failure, in dsh's shape. */
export interface StreamError {
  code: string
  message: string
  details: unknown
}

/** What a stream's opener hears. Each is called at most once after `end` or `error`. */
export interface StreamSink {
  item: (value: unknown) => void
  end: () => void
  error: (error: StreamError) => void
}

/** The opener's handle on a stream. */
export interface StreamHandle {
  /** Send one uplink item. */
  item: (value: unknown) => void
  /** Half-close the uplink. */
  end: () => void
  /** Stop the stream; nothing more is delivered to its sink. */
  cancel: () => void
}

/**
 * Reconnect delays, the ceilings dsh's own client uses (each delay is a random
 * 50–100% of its ceiling, and the last one repeats).
 */
const BACKOFF_MS = [500, 1_000, 2_000, 4_000, 8_000, 10_000]

/** Connection state, for status. */
export interface MuxState {
  connected: boolean
  /** Why not, when not. */
  detail?: string
}

/** One signed-in connection to dsh's stream endpoint, redialled until stopped. */
export class RemoteMux {
  private readonly base: URL
  private socket: WebSocket | undefined
  private readonly streams = new Map<string, StreamSink>()
  private counter = 0
  private attempt = 0
  private timer: NodeJS.Timeout | undefined
  private stopped = true
  private current: MuxState = { connected: false, detail: 'not connected yet' }
  private readonly listeners = new Set<(state: MuxState) => void>()

  /** @param baseUrl - the loopback base URL of dsh. */
  constructor(baseUrl: string) {
    this.base = assertLoopback(baseUrl)
  }

  /** The connection as of now. */
  get state(): MuxState {
    return this.current
  }

  /** Start connecting, and keep reconnecting until {@link stop}. */
  start(): void {
    if (!this.stopped) return
    this.stopped = false
    this.dial()
  }

  /** Close the connection for good; every open stream fails. */
  stop(): void {
    this.stopped = true
    if (this.timer !== undefined) clearTimeout(this.timer)
    this.timer = undefined
    const socket = this.socket
    this.socket = undefined
    socket?.terminate()
    this.failAll('the Bridle is shutting down')
    this.publish({ connected: false, detail: 'stopped' })
  }

  /**
   * Watch the connection.
   * @param listener - called on every change.
   * @returns a function that stops watching.
   */
  onState(listener: (state: MuxState) => void): () => void {
    this.listeners.add(listener)
    return (): void => { this.listeners.delete(listener) }
  }

  /**
   * Open a stream. When dsh is not connected right now the stream fails at
   * once — queuing it would hand the opener a baseline from a dsh that may no
   * longer be the one it asked.
   * @param endpoint - e.g. `session/follow`, or `$events`.
   * @param args - the endpoint's arguments.
   * @param sink - receives the stream's items, then its end or error.
   * @returns the handle to send on or cancel it.
   */
  open(endpoint: string, args: unknown, sink: StreamSink): StreamHandle {
    const socket = this.socket
    if (socket === undefined || socket.readyState !== WebSocket.OPEN || !this.current.connected) {
      queueMicrotask(() => {
        sink.error({ code: 'upstream-lost', message: `dsh is not connected (${this.current.detail ?? 'reconnecting'})`, details: {} })
      })
      return { item: () => {}, end: () => {}, cancel: () => {} }
    }
    this.counter += 1
    const streamId = `b${String(this.counter)}`
    this.streams.set(streamId, sink)
    this.write(socket, { type: 'open', streamId, endpoint, payload: { args } })
    return {
      item: (value) => {
        if (this.streams.has(streamId)) this.write(socket, { type: 'item', streamId, value })
      },
      end: () => {
        if (this.streams.has(streamId)) this.write(socket, { type: 'end', streamId })
      },
      cancel: () => {
        // dsh sends nothing after a cancel; forgetting the stream first means a
        // frame already in flight cannot reach a sink that has moved on.
        if (!this.streams.delete(streamId)) return
        this.write(socket, { type: 'cancel', streamId })
      },
    }
  }

  private dial(): void {
    if (this.stopped) return
    const address = new URL('/api/remote.mux', this.base)
    address.protocol = 'ws:'
    const cookie = cookieFor(this.base.origin)
    const socket = new WebSocket(address, {
      headers: { host: this.base.host, ...(cookie === undefined ? {} : { cookie }) },
      // dsh pings every two seconds and drops a client that misses two; `ws`
      // answers pings itself.
    })
    this.socket = socket
    let refusal: string | undefined

    socket.on('unexpected-response', (_request, response) => {
      const status = response.statusCode ?? 0
      if (status === 401 && cookie !== undefined) forgetCookie(this.base.origin, cookie)
      refusal = status === 401
        ? 'dsh asks to sign in — run "bridle plugin install" and restart dsh, or let bridle start dsh'
        : status === 404
          ? 'dsh has no stream endpoint (dsh 0.1, or still starting)'
          : `dsh refused the stream connection (HTTP ${String(status)})`
      socket.terminate()
    })
    socket.on('open', () => {
      this.attempt = 0
      this.publish({ connected: true })
    })
    socket.on('message', (data, binary) => {
      if (binary) return
      this.deliver(data.toString())
    })
    socket.on('error', (error: Error) => {
      refusal ??= error.message
    })
    socket.on('close', () => {
      if (this.socket !== socket) return
      this.socket = undefined
      this.failAll('the connection to dsh dropped')
      this.publish({ connected: false, detail: refusal ?? 'the connection to dsh dropped' })
      this.scheduleRedial()
    })
  }

  private scheduleRedial(): void {
    if (this.stopped) return
    const ceiling = BACKOFF_MS[Math.min(this.attempt, BACKOFF_MS.length - 1)] ?? 10_000
    this.attempt += 1
    this.timer = setTimeout(() => {
      this.timer = undefined
      this.dial()
    }, ceiling * (0.5 + Math.random() * 0.5))
    this.timer.unref()
  }

  private deliver(text: string): void {
    let frame: { type?: unknown; streamId?: unknown; value?: unknown; error?: unknown }
    try {
      frame = JSON.parse(text) as typeof frame
    } catch {
      return
    }
    if (typeof frame.streamId !== 'string') return
    const sink = this.streams.get(frame.streamId)
    if (sink === undefined) return
    switch (frame.type) {
      case 'item':
        sink.item(frame.value)
        return
      case 'end':
        this.streams.delete(frame.streamId)
        sink.end()
        return
      case 'error':
        this.streams.delete(frame.streamId)
        sink.error(asError(frame.error))
        return
      default:
        return
    }
  }

  private failAll(why: string): void {
    const sinks = [...this.streams.values()]
    this.streams.clear()
    for (const sink of sinks) {
      try {
        sink.error({ code: 'upstream-lost', message: why, details: {} })
      } catch {
        // One opener's failure must not keep the rest from hearing.
      }
    }
  }

  private write(socket: WebSocket, frame: unknown): void {
    if (socket.readyState !== WebSocket.OPEN) return
    socket.send(JSON.stringify(frame))
  }

  private publish(next: MuxState): void {
    if (next.connected === this.current.connected && next.detail === this.current.detail) return
    this.current = next
    for (const listener of this.listeners) {
      try {
        listener(next)
      } catch {
        // Same as everywhere else: one bad listener must not stall the rest.
      }
    }
  }
}

function asError(raw: unknown): StreamError {
  const error = raw as { code?: unknown; message?: unknown; details?: unknown } | undefined
  return {
    code: typeof error?.code === 'string' ? error.code : 'internal',
    message: typeof error?.message === 'string' ? error.message : 'dsh ended the stream with an error',
    details: error?.details ?? {},
  }
}
