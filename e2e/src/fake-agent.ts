/**
 * A harness that does exactly what a test tells it to.
 *
 * The real dsh is the right thing to test against for most of the suite. But
 * some behaviour cannot be provoked on cue: an approval arriving at a chosen
 * instant, a question with a known shape, the connection to dsh dropping
 * mid-turn. Waiting for a model to decide to run `rm` is not a test, it is a
 * hope.
 *
 * So this implements the seam the Bridle talks to (`AgentClient`) and hands the
 * test a lever for each of those moments. Its `$events` behaves the way dsh
 * 0.2's does (docs/dsh-0.2-protocol.md §5): every new stream gets a `ready`
 * with a fresh `clientId` and then every waterfall still pending, under the
 * same `eventId`; the first `$events/result` wins, and every other holder is
 * sent `cancel`; a late answer is accepted and changes nothing.
 */

import { randomUUID } from 'node:crypto'
import type { AgentClient, AgentResult, MuxState, StreamHandle, StreamSink } from '@rowel/bridle'

/** One call the Bridle forwarded, recorded for assertions. */
export interface RecordedCall {
  endpoint: string
  args: unknown
}

/** One stream the Bridle opened, recorded for assertions. */
export interface RecordedStream {
  endpoint: string
  args: unknown
  /** Whether it was cancelled by the Bridle. */
  cancelled: boolean
  /** Uplink items it received. */
  uplink: unknown[]
}

interface OpenStream {
  record: RecordedStream
  sink: StreamSink
  /** Set for `$events` streams. */
  clientId?: string
}

interface Waterfall {
  event: string
  eventId: string
  agentId: string
  request: unknown
  /** Clients still holding it. */
  holders: Set<string>
}

export class FakeAgent implements AgentClient {
  readonly baseUrl = 'http://127.0.0.1:0'
  /** Every unary call the Bridle forwarded, in order. */
  readonly calls: RecordedCall[] = []
  /** Every stream the Bridle opened, in order. */
  readonly opened: RecordedStream[] = []
  /** Every answer that reached a waterfall, first one first. */
  readonly answers: Array<{ clientId: string; eventId: string; outcome: unknown }> = []

  private readonly live = new Set<OpenStream>()
  private readonly waterfalls = new Map<string, Waterfall>()
  private readonly connectionListeners = new Set<(state: MuxState) => void>()
  private state: MuxState = { connected: false, detail: 'not started' }

  /** Answers keyed by endpoint; anything unlisted returns an empty object. */
  readonly results = new Map<string, AgentResult>()
  private readonly handlers = new Map<string, (args: any) => AgentResult>()
  private readonly streamHandlers = new Map<string, (args: any, emit: StreamSink) => void>()

  /**
   * Answer this endpoint by running a function over its arguments.
   * @param endpoint - the endpoint to intercept.
   * @param handler - called with the args; its return value is the answer.
   */
  handle(endpoint: string, handler: (args: any) => AgentResult): void {
    this.handlers.set(endpoint, handler)
  }

  /**
   * Serve a stream endpoint.
   * @param endpoint - e.g. `session/follow`.
   * @param handler - called with the args and the sink to emit on.
   */
  serve(endpoint: string, handler: (args: any, emit: StreamSink) => void): void {
    this.streamHandlers.set(endpoint, handler)
  }

  start(): void {
    this.setConnected(true)
  }

  stop(): void {
    this.setConnected(false, 'stopped')
  }

  get connection(): MuxState {
    return this.state
  }

  onConnection(listener: (state: MuxState) => void): () => void {
    this.connectionListeners.add(listener)
    return (): void => { this.connectionListeners.delete(listener) }
  }

  async call(endpoint: string, args: unknown): Promise<AgentResult> {
    this.calls.push({ endpoint, args })
    if (endpoint === '$events/result') return this.result(args)
    const handler = this.handlers.get(endpoint)
    if (handler !== undefined) return handler(args)
    return this.results.get(endpoint) ?? { ok: true, value: {} }
  }

  open(endpoint: string, args: unknown, sink: StreamSink): StreamHandle {
    const record: RecordedStream = { endpoint, args, cancelled: false, uplink: [] }
    this.opened.push(record)
    if (!this.state.connected) {
      queueMicrotask(() => { sink.error({ code: 'upstream-lost', message: 'the fake harness is down', details: {} }) })
      return { item: () => {}, end: () => {}, cancel: () => {} }
    }
    const stream: OpenStream = { record, sink }
    this.live.add(stream)
    if (endpoint === '$events') {
      stream.clientId = randomUUID()
      sink.item({ type: 'ready', clientId: stream.clientId, host: { home: '/Users/fake' } })
      for (const waterfall of this.waterfalls.values()) {
        waterfall.holders.add(stream.clientId)
        sink.item(this.frameOf(waterfall))
      }
    } else {
      const handler = this.streamHandlers.get(endpoint)
      if (handler === undefined) {
        queueMicrotask(() => {
          this.live.delete(stream)
          sink.error({ code: 'gateway/not-found', message: `the fake harness does not serve ${endpoint}`, details: {} })
        })
      } else {
        handler(args, {
          item: (value) => { if (this.live.has(stream)) sink.item(value) },
          end: () => { if (this.live.delete(stream)) sink.end() },
          error: (error) => { if (this.live.delete(stream)) sink.error(error) },
        })
      }
    }
    return {
      item: (value) => { record.uplink.push(value) },
      end: () => {},
      cancel: () => {
        record.cancelled = true
        this.live.delete(stream)
        if (stream.clientId !== undefined) for (const waterfall of this.waterfalls.values()) waterfall.holders.delete(stream.clientId)
      },
    }
  }

  async export(): Promise<Response> {
    return new Response(Buffer.from('fake archive'), { headers: { 'content-type': 'application/zip' } })
  }

  // MARK: - Levers

  /**
   * Ask for approval of a tool call, the way dsh does.
   * @param options - which session, and what is being approved.
   * @returns the eventId an answer has to name.
   */
  requestApproval(options: { sessionId: string; toolName: string; reason?: string }): string {
    return this.waterfall('approval/request', options.sessionId, {
      toolName: options.toolName,
      callId: `call-${String(this.waterfalls.size + 1)}`,
      ...(options.reason === undefined ? {} : { reason: options.reason }),
    })
  }

  /**
   * Ask the person a question, the way dsh does.
   * @param options - which session, and what to ask.
   * @returns the eventId an answer has to name.
   */
  askQuestion(options: { sessionId: string; question: string; options: string[] }): string {
    return this.waterfall('user-questions/request', options.sessionId, {
      questions: [{ id: 'q1', question: options.question, options: options.options.map(label => ({ label })) }],
    })
  }

  /**
   * End a waterfall without an answer, as a cancelled turn does.
   * @param eventId - the waterfall.
   */
  withdraw(eventId: string): void {
    const waterfall = this.waterfalls.get(eventId)
    if (waterfall === undefined) return
    this.waterfalls.delete(eventId)
    this.broadcast(waterfall.holders, { type: 'cancel', eventId })
  }

  /**
   * Drop or restore the connection the Bridle holds, the way a dsh restart or
   * a dropped socket does: every open stream fails with `upstream-lost`.
   * @param connected - the new state.
   * @param detail - why, when down.
   */
  setConnected(connected: boolean, detail = 'the fake harness was told to be down'): void {
    if (!connected) {
      for (const stream of [...this.live]) {
        this.live.delete(stream)
        stream.sink.error({ code: 'upstream-lost', message: detail, details: {} })
      }
      for (const waterfall of this.waterfalls.values()) waterfall.holders.clear()
    }
    const next: MuxState = connected ? { connected: true } : { connected: false, detail }
    if (next.connected === this.state.connected && next.detail === this.state.detail) return
    this.state = next
    for (const listener of this.connectionListeners) listener(next)
  }

  /** How many `$events` streams are open right now. */
  get eventStreams(): number {
    return [...this.live].filter(stream => stream.clientId !== undefined).length
  }

  private waterfall(event: string, agentId: string, request: unknown): string {
    const eventId = randomUUID()
    const holders = new Set<string>()
    for (const stream of this.live) if (stream.clientId !== undefined) holders.add(stream.clientId)
    const waterfall: Waterfall = { event, eventId, agentId, request, holders }
    this.waterfalls.set(eventId, waterfall)
    this.broadcast(holders, this.frameOf(waterfall))
    return eventId
  }

  private result(args: unknown): AgentResult {
    const { clientId, eventId, outcome } = (args ?? {}) as { clientId?: unknown; eventId?: unknown; outcome?: unknown }
    if (typeof clientId !== 'string' || ![...this.live].some(stream => stream.clientId === clientId)) {
      return { ok: false, error: { code: 'gateway/internal', message: 'Remote event result identifies no active event stream', details: {} } }
    }
    const waterfall = typeof eventId === 'string' ? this.waterfalls.get(eventId) : undefined
    // A late or unknown answer is accepted and changes nothing, as on dsh.
    if (waterfall === undefined || !waterfall.holders.has(clientId)) return { ok: true, value: { ok: true } }
    this.answers.push({ clientId, eventId: waterfall.eventId, outcome })
    this.waterfalls.delete(waterfall.eventId)
    waterfall.holders.delete(clientId)
    this.broadcast(waterfall.holders, { type: 'cancel', eventId: waterfall.eventId })
    return { ok: true, value: { ok: true } }
  }

  private frameOf(waterfall: Waterfall): unknown {
    return { type: 'waterfall', event: waterfall.event, eventId: waterfall.eventId, agentId: waterfall.agentId, request: waterfall.request }
  }

  private broadcast(clientIds: Set<string>, value: unknown): void {
    for (const stream of this.live) {
      if (stream.clientId !== undefined && clientIds.has(stream.clientId)) stream.sink.item(value)
    }
  }
}
