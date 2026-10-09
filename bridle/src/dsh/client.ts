/**
 * Loopback client for a running dsh web server. Speaks the exact wire the
 * browser speaks: unary methods as `POST /api/<method>` carrying a
 * `client-request` envelope, answers to approvals and questions as
 * `POST /api/respond`, and the two downlinks as WebSockets that only ever
 * receive.
 *
 * dsh 0.1.1 has no authentication; its fence is the Host header plus a
 * loopback bind. dsh 0.2 adds a signed cookie on every request, loopback
 * included; whatever cookie is known for this address (`credentials.ts`) rides
 * along on every call and socket, and one that is refused is dropped. Nothing
 * in this file may ever be pointed at a non-loopback dsh — {@link assertLoopback}
 * enforces that at construction.
 */

import { isIP } from 'node:net'
import WebSocket from 'ws'
import type { AgentClient } from '../agents/types.ts'
import { cookieFor, forgetCookie } from './credentials.ts'

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

/** Result of one dsh reachability probe. */
export interface DshHealth {
  reachable: boolean
  /** `host.describe` value when reachable. */
  host?: unknown
  /** Operator-facing reason when unreachable. */
  detail?: string
}

/** Options for {@link DshClient}. */
export interface DshClientOptions {
  /** Loopback base URL of the dsh web server. */
  baseUrl: string
  /** Milliseconds before an idle unary request is abandoned. */
  requestTimeoutMs?: number
}

/** Default ceiling for one unary call; long-running work streams over the downlinks instead. */
const DEFAULT_REQUEST_TIMEOUT_MS = 120_000

/** How long to wait before redialing a dropped downlink. */
const STREAM_RETRY_MS = 1_000

let rpcCounter = 0

function nextRpcId(): string {
  rpcCounter += 1
  return `bridle-${String(process.pid)}-${String(rpcCounter)}`
}

/** Unary and streaming access to one loopback dsh. */
export class DshClient implements AgentClient {
  private readonly base: URL
  private readonly requestTimeoutMs: number

  /** @param options - the loopback base URL and timeouts. */
  constructor(options: DshClientOptions) {
    this.base = assertLoopback(options.baseUrl)
    this.requestTimeoutMs = options.requestTimeoutMs ?? DEFAULT_REQUEST_TIMEOUT_MS
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

  /** A refusal of the cookie that was sent means it is no good any more. */
  private refused(status: number, sent: Record<string, string>): void {
    if (status === 401 && sent['cookie'] !== undefined) forgetCookie(this.base.origin)
  }

  /**
   * Invoke one dsh method.
   * @param method - path segment, e.g. `session.list` or `goals/create`.
   * @param payload - the method's request payload.
   * @param signal - abandons the call; dsh maps it onto its own AbortSignal.
   * @returns the business result; carrier failures fold into the error branch.
   */
  async call(method: string, payload: unknown, signal?: AbortSignal): Promise<DshResult> {
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
      return carrierFailure(signal?.aborted === true ? 'cancelled' : 'internal', method, error)
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
   * Answer an approval or question by echoing the frame's rpcId.
   * @param message - the dsh `client-response` message, verbatim.
   * @returns the carrier receipt dsh reports.
   */
  async respond(message: unknown): Promise<unknown> {
    const response = await fetch(new URL('/api/respond', this.base), {
      method: 'POST',
      headers: { 'content-type': 'application/json', ...this.credentials() },
      body: JSON.stringify(message),
      signal: AbortSignal.timeout(this.requestTimeoutMs),
    })
    if (!response.ok) throw new Error(`dsh /api/respond answered HTTP ${String(response.status)}`)
    return response.json()
  }

  /**
   * Probe whether dsh is up.
   * @returns reachability plus the `host.describe` value when it answers.
   */
  async health(): Promise<DshHealth> {
    try {
      const result = await this.call('host.describe', {}, AbortSignal.timeout(3_000))
      if (result.ok) return { reachable: true, host: result.value }
      return { reachable: false, detail: result.error.message }
    } catch (error) {
      return { reachable: false, detail: describe(error) }
    }
  }

  /**
   * Stream one downlink, redialing until the signal aborts. dsh treats any
   * client message on these sockets as a protocol violation, so this never
   * writes.
   * @param stream - which downlink to open.
   * @param onFrame - receives each `server-request` frame verbatim.
   * @param onState - reports connect and disconnect transitions.
   * @param signal - stops the stream and its retries.
   */
  async pump(
    stream: 'mux' | 'host',
    onFrame: (frame: unknown) => void,
    onState: (connected: boolean, detail?: string) => void,
    signal: AbortSignal,
  ): Promise<void> {
    const address = new URL(`/api/events.${stream}`, this.base)
    address.protocol = address.protocol === 'https:' ? 'wss:' : 'ws:'
    while (!signal.aborted) {
      const closed = await this.pumpOnce(address, onFrame, onState, signal)
      if (signal.aborted) return
      onState(false, closed)
      await sleep(STREAM_RETRY_MS, signal)
    }
  }

  private pumpOnce(
    address: URL,
    onFrame: (frame: unknown) => void,
    onState: (connected: boolean, detail?: string) => void,
    signal: AbortSignal,
  ): Promise<string | undefined> {
    return new Promise((resolve) => {
      const socket = new WebSocket(address, { headers: { host: this.base.host, ...this.credentials() } })
      let settled = false
      const settle = (detail?: string): void => {
        if (settled) return
        settled = true
        signal.removeEventListener('abort', onAbort)
        resolve(detail)
      }
      const onAbort = (): void => {
        socket.close()
        settle()
      }
      signal.addEventListener('abort', onAbort, { once: true })
      socket.on('open', () => { onState(true) })
      socket.on('message', (data) => {
        try {
          onFrame(JSON.parse(data.toString()))
        } catch {
          // A frame dsh could not have produced; dropping one malformed frame
          // is strictly better than tearing down a live conversation.
        }
      })
      socket.on('error', (error: Error) => { settle(error.message) })
      socket.on('close', () => { settle('dsh closed the downlink') })
    })
  }

  /**
   * Proxy a session-log export.
   * @param sessionId - root session to export.
   * @param includeDescendants - whether subagent sessions ride along.
   * @returns the raw ZIP response from dsh.
   */
  export(sessionId: string, includeDescendants: boolean): Promise<Response> {
    const url = new URL('/api/session.export', this.base)
    url.searchParams.set('sessionId', sessionId)
    if (includeDescendants) url.searchParams.set('includeDescendants', 'true')
    return fetch(url, { headers: this.credentials() })
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
