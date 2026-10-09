/**
 * Loopback client for a running dsh 0.2 web server. Speaks the wire the
 * browser speaks: a unary endpoint as `POST /api/<endpoint>` carrying a
 * `client-request` envelope whose payload is `{ args }`, and every stream as a
 * logical stream on one `/api/remote.mux` socket (`remote-mux.ts`).
 *
 * dsh 0.2 lets nothing into `/api` without a signed cookie, loopback included.
 * Whatever cookie is known for this address (`credentials.ts`) rides along on
 * every call and socket, and one that is refused is dropped. Nothing in this
 * file may ever be pointed at a non-loopback dsh — {@link assertLoopback}
 * enforces that at construction.
 */

import { isIP } from 'node:net'
import type { AgentClient } from '../agents/types.ts'
import { cookieFor, forgetCookie } from './credentials.ts'
import { RemoteMux, type MuxState, type StreamHandle, type StreamSink } from './remote-mux.ts'

/** The dsh unary response body. */
export type DshResult =
  | { ok: true; value: unknown }
  | { ok: false; error: { code: string; message: string; details: unknown } }

/** Hostnames that mean "this machine" and therefore satisfy the dsh trust fence. */
const LOOPBACK_HOSTNAMES = new Set(['localhost', '127.0.0.1', '::1', '[::1]'])

/**
 * Refuse any dsh base URL that is not loopback.
 * @param base - the configured dsh base URL.
 * @throws {@link Error} when the URL would send harness traffic off the machine.
 */
export function assertLoopback(base: string): URL {
  const url = new URL(base)
  const host = url.hostname
  const loopback = LOOPBACK_HOSTNAMES.has(host)
    || (isIP(host) === 4 && host.startsWith('127.'))
  if (!loopback) {
    throw new Error(`dsh URL must be loopback, got ${JSON.stringify(base)}`)
  }
  return url
}

/** Options for {@link DshClient}. */
export interface DshClientOptions {
  /** Loopback base URL of the dsh web server. */
  baseUrl: string
  /** Milliseconds before an idle unary request is abandoned. */
  requestTimeoutMs?: number
}

/** Default ceiling for one unary call; long-running work streams instead. */
const DEFAULT_REQUEST_TIMEOUT_MS = 120_000

let rpcCounter = 0

function nextRpcId(): string {
  rpcCounter += 1
  return `bridle-${String(process.pid)}-${String(rpcCounter)}`
}

/** Unary and streaming access to one loopback dsh. */
export class DshClient implements AgentClient {
  private readonly base: URL
  private readonly requestTimeoutMs: number
  private readonly mux: RemoteMux

  /** @param options - the loopback base URL and timeouts. */
  constructor(options: DshClientOptions) {
    this.base = assertLoopback(options.baseUrl)
    this.requestTimeoutMs = options.requestTimeoutMs ?? DEFAULT_REQUEST_TIMEOUT_MS
    this.mux = new RemoteMux(this.base.origin)
  }

  /** Begin connecting the stream socket. */
  start(): void {
    this.mux.start()
  }

  /** Close the stream socket for good. */
  stop(): void {
    this.mux.stop()
  }

  /** Whether the stream socket is connected. */
  get connection(): MuxState {
    return this.mux.state
  }

  /**
   * Watch the stream socket.
   * @param listener - called on every change.
   * @returns a function that stops watching.
   */
  onConnection(listener: (state: MuxState) => void): () => void {
    return this.mux.onState(listener)
  }

  /**
   * Open a stream on the shared socket.
   * @param endpoint - e.g. `session/follow`, or `$events`.
   * @param args - the endpoint's arguments.
   * @param sink - receives items, then the end or an error.
   * @returns the handle.
   */
  open(endpoint: string, args: unknown, sink: StreamSink): StreamHandle {
    return this.mux.open(endpoint, args, sink)
  }

  /** The configured base URL. */
  get baseUrl(): string {
    return this.base.origin
  }

  /**
   * The cookie header for this address, when one is known. Asked per request,
   * not held: the dsh plugin learns its cookie after the client exists.
   */
  private credentials(): Record<string, string> {
    const cookie = cookieFor(this.base.origin)
    return cookie === undefined ? {} : { cookie }
  }

  /**
   * A refusal of the cookie that was sent means it is no good any more. Every
   * path that sends one comes through here, so a stale cookie is dropped
   * wherever it is refused first.
   */
  private refused(status: number, sent: Record<string, string>): void {
    const cookie = sent['cookie']
    if (status === 401 && cookie !== undefined) forgetCookie(this.base.origin, cookie)
  }

  /**
   * Invoke one dsh endpoint.
   * @param endpoint - `<namespace>/<method>`, e.g. `session/list`.
   * @param args - the endpoint's arguments; dsh wants exactly the names it declares.
   * @param signal - abandons the call; dsh maps it onto its own AbortSignal.
   * @returns the business result; carrier failures fold into the error branch.
   */
  async call(endpoint: string, args: unknown, signal?: AbortSignal): Promise<DshResult> {
    const method = endpoint
    const payload = { args }
    const timeout = AbortSignal.timeout(this.requestTimeoutMs)
    const composite = signal === undefined ? timeout : AbortSignal.any([signal, timeout])
    const rpcId = nextRpcId()
    const sent = this.credentials()
    let response: Response
    try {
      response = await fetch(new URL(`/api/${method}`, this.base), {
        method: 'POST',
        headers: { 'content-type': 'application/json', ...sent },
        body: JSON.stringify({ type: 'client-request', rpcId, method, payload }),
        signal: composite,
      })
    } catch (error) {
      // Three different endings, and the app retries two of them: the caller
      // gave up, dsh did not answer in time, or the connection failed.
      const code = signal?.aborted === true ? 'cancelled' : timeout.aborted ? 'timeout' : 'internal'
      return carrierFailure(code, method, error)
    }
    if (!response.ok) {
      this.refused(response.status, sent)
      const text = await response.text().catch(() => '')
      return {
        ok: false,
        error: {
          code: 'internal',
          message: `dsh answered HTTP ${String(response.status)}${text === '' ? '' : `: ${text}`}`,
          details: {},
        },
      }
    }
    let body: unknown
    try {
      body = await response.json()
    } catch (error) {
      return carrierFailure('internal', method, error)
    }
    const envelope = body as { type?: unknown; result?: DshResult }
    if (envelope.type !== 'server-response' || envelope.result === undefined) {
      return { ok: false, error: { code: 'internal', message: 'dsh returned a malformed envelope', details: {} } }
    }
    return envelope.result
  }

  /**
   * Proxy a session-log export.
   * @param sessionId - root session to export.
   * @param includeDescendants - whether subagent sessions ride along.
   * @returns the raw ZIP response from dsh.
   */
  export(sessionId: string, includeDescendants: boolean, signal?: AbortSignal): Promise<Response> {
    const url = new URL('/api/session.export', this.base)
    url.searchParams.set('sessionId', sessionId)
    if (includeDescendants) url.searchParams.set('includeDescendants', 'true')
    const sent = this.credentials()
    return fetch(url, { headers: sent, ...(signal === undefined ? {} : { signal }) }).then((response) => {
      this.refused(response.status, sent)
      return response
    })
  }
}

/**
 * Turn a thrown carrier error into a result the phone can read.
 *
 * Node reports every connection-level fetch failure as the same three words —
 * `fetch failed` — and puts the reason that would actually identify it
 * (`ECONNREFUSED`, a socket closed mid-body, a name that did not resolve) one
 * level down in `cause`. Forwarding just the message hands the phone a string
 * that names no method, no address and no cause, and someone then has to debug
 * from that. This is the whole reason the chain is unwrapped: the phone is the
 * only place the error is ever seen, so it has to arrive complete.
 * @param code - the error code the app switches on.
 * @param method - the dsh method being called, for the message.
 * @param error - whatever was thrown.
 * @returns the failure, described down to its root cause.
 */
function carrierFailure(code: string, method: string, error: unknown): DshResult {
  return { ok: false, error: { code, message: `${method}: ${describe(error)}`, details: {} } }
}

/** How deep to follow `cause` before the message is doing more harm than good. */
const MAX_CAUSE_DEPTH = 4

/**
 * Flatten an error and its causes into one line.
 * @param error - the thrown value.
 * @returns the messages, outermost first, joined by `: `.
 */
function describe(error: unknown): string {
  if (!(error instanceof Error)) return String(error)
  const chain: string[] = []
  let current: unknown = error
  while (current instanceof Error && chain.length < MAX_CAUSE_DEPTH) {
    // A cause that merely repeats its wrapper adds length and no information.
    if (chain.at(-1) !== current.message) chain.push(current.message)
    current = current.cause
  }
  return chain.join(': ')
}
