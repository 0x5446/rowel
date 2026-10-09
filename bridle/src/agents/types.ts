/**
 * The one seam between the Bridle and whatever agent it is fronting.
 *
 * Everything above this line — the Noise tunnel, pairing, the Relay client, the
 * direct listener, push — is agent-agnostic. Everything below it speaks one
 * agent's wire protocol. A test double stands in here without pretending to be
 * an HTTP server.
 *
 * Since tunnel version 2 the seam is dsh 0.2's own shape, deliberately: a unary
 * call by endpoint, a stream by endpoint, and the state of the connection that
 * carries the streams. The Bridle forwards both without reading them
 * (docs/dsh-0.2-migration.md D3), so a second agent would need its own app-side
 * client, not just another implementation of this interface.
 */

import type { StreamHandle, StreamSink, MuxState } from '../dsh/remote-mux.ts'

export type { StreamError, StreamHandle, StreamSink, MuxState } from '../dsh/remote-mux.ts'

/**
 * Result of one unary agent call.
 *
 * A discriminated union rather than `{ ok: boolean, value?, error? }`: the
 * looser shape lets a caller read `value` on a failure and get `undefined`
 * instead of a type error, which is exactly the mistake this boundary should
 * make impossible.
 */
export type AgentResult =
  | { ok: true; value: unknown }
  | { ok: false; error: { code: string; message: string; details: unknown } }

/** Unary and streaming access to one local agent. */
export interface AgentClient {
  /** The address this client talks to, for diagnostics. */
  readonly baseUrl: string

  /** Begin connecting the stream carrier, and keep it connected until {@link stop}. */
  start: () => void

  /** Close the stream carrier for good. */
  stop: () => void

  /** Whether the stream carrier is connected right now, and why not. */
  readonly connection: MuxState

  /**
   * Watch the stream carrier.
   * @param listener - called on every change.
   * @returns a function that stops watching.
   */
  onConnection: (listener: (state: MuxState) => void) => () => void

  /**
   * Invoke one unary endpoint.
   * @param endpoint - `<namespace>/<method>`, passed through opaquely.
   * @param args - the endpoint's arguments.
   * @param signal - abandons the call.
   * @returns the business result; carrier failures fold into the error branch.
   */
  call: (endpoint: string, args: unknown, signal?: AbortSignal) => Promise<AgentResult>

  /**
   * Open a stream.
   * @param endpoint - e.g. `session/follow`, or `$events`.
   * @param args - the endpoint's arguments.
   * @param sink - receives the stream's items, then its end or error.
   * @returns the handle to send on or cancel it.
   */
  open: (endpoint: string, args: unknown, sink: StreamSink) => StreamHandle

  /**
   * Export a session as an archive.
   * @param sessionId - the session to export.
   * @param includeDescendants - whether to include subagent sessions.
   * @returns the raw HTTP response, so the caller can read headers and bytes.
   */
  export: (sessionId: string, includeDescendants: boolean) => Promise<Response>
}
