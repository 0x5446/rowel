/**
 * Tunnel frames: the application protocol carried inside the Noise channel.
 * One tunnel multiplexes every dsh interaction — unary calls, any number of
 * dsh streams, and cancellation of either — so the phone holds exactly one
 * socket.
 *
 * Version 2 is dsh 0.2's own API, passed through. A `call` is
 * `POST /api/<endpoint>` and a stream is a logical stream on dsh's
 * `/api/remote.mux`, frame for frame: the Bridle signs in, keeps one
 * connection to dsh, and maps stream ids. It does not know what any endpoint
 * means, so a new dsh endpoint is a change to the app alone
 * (docs/dsh-0.2-migration.md D3).
 *
 * Frames are JSON. The dsh API is JSON end to end (attachments ride as base64
 * inside it), so a binary framing would buy nothing and cost debuggability.
 */

/** The tunnel version this build speaks. */
export const TUNNEL_VERSION = 2

/**
 * Versions this build can speak, preferred first.
 *
 * A set rather than a number, because the two ends update independently: a
 * phone sits in the App Store review queue while the Bridle is a `npm
 * install` away, and after release version skew is the normal case rather
 * than the exception. Both ends offer what they can speak and the responder
 * picks the highest they share.
 */
/**
 * Largest single tunnel message any hop will carry, in bytes.
 *
 * A ceiling rather than a preference: every WebSocket implementation on the
 * path enforces one, and all of them enforce it the same brutal way — the
 * oversized message is never delivered and the *connection* is closed with a
 * 1009. There is no per-request failure and nothing to catch, so a sender that
 * does not check first produces a tunnel that drops, reconnects, resumes,
 * resends the same frame and drops again, with no layer able to say why.
 *
 * Which is why this is shared: both ends check against it before writing, so
 * the failure lands on the one request responsible instead of on the tunnel.
 *
 * 32 MiB is Cloudflare's limit for a message received by a Worker, and the
 * lowest ceiling on any path this protocol is deployed over. The Node relay
 * could carry more; matching the smallest one means a Bridle does not behave
 * differently depending on which relay it happens to be dialling.
 */
export const MAX_FRAME_BYTES = 32 * 1024 * 1024

/**
 * Only version 2. The protocol's rule is to speak the current version and the
 * one before (docs/protocol.md §4.6), and this is the deliberate exception:
 * version 1 was dsh 0.1's API passed through, dsh 0.2 removed that API, and
 * the owner chose not to keep a translation layer for it. An app that only
 * speaks 1 is refused in the handshake with `supported: [2]`, which it already
 * turns into "update the app" — the one useful thing it could be told.
 */
export const TUNNEL_VERSIONS: readonly number[] = [2]

/**
 * Noise prologue both ends mix in before the first handshake message.
 *
 * Deliberately carries no version. An earlier design put one here, which made
 * a mismatch fail *inside* the handshake — before any channel exists, so the
 * refusal could not be sent and the client could not tell version skew from a
 * wrong machine key from tampering. The version is negotiated in the handshake
 * payload instead (see `HelloFrame` / `HandshakeReply`), which works because
 * the responder can always decrypt message one and can therefore always answer
 * with an *authenticated* refusal.
 */
export const TUNNEL_PROLOGUE: Buffer = Buffer.from('rowel-tunnel', 'utf8')

/**
 * Choose the version two ends will speak.
 * @param offered - what the initiator says it supports, preferred first.
 * @param supported - what this build supports.
 * @returns the highest shared version, or undefined when there is no overlap.
 */
export function negotiateVersion(
  offered: readonly number[] | undefined,
  supported: readonly number[] = TUNNEL_VERSIONS,
): number | undefined {
  // An absent or empty list is the oldest client, which predates negotiation
  // and can only speak version 1.
  const wanted = offered === undefined || offered.length === 0 ? [1] : offered
  const shared = wanted.filter(version => supported.includes(version))
  return shared.length === 0 ? undefined : Math.max(...shared)
}

/** A failure, in dsh's own shape. */
export interface FrameError {
  code: string
  message: string
  details: unknown
}

/** The outcome of one unary call. */
export type CallResult = { ok: true; value: unknown } | { ok: false; error: FrameError }

/** App to Bridle: invoke one unary dsh endpoint (`POST /api/<endpoint>`). */
export interface CallFrame {
  t: 'call'
  /** App-minted correlation id, unique per tunnel. */
  id: string
  /** dsh endpoint, `<namespace>/<method>`, e.g. `session/list`. */
  endpoint: string
  /** The endpoint's arguments: dsh's `payload.args`, verbatim. */
  args: unknown
}

/** Bridle to App: the outcome of one {@link CallFrame}. */
export interface ResultFrame {
  t: 'result'
  id: string
  /** dsh's `server-response.result`, or a failure the Bridle made itself. */
  result: CallResult
}

/** App to Bridle: abandon an in-flight call. Unknown ids are ignored. */
export interface AbortFrame {
  t: 'abort'
  id: string
}

/** App to Bridle: open a dsh stream (a logical stream on `/api/remote.mux`). */
export interface OpenFrame {
  t: 'open'
  /** App-minted stream id, unique per tunnel among streams still open. */
  sid: string
  /** dsh endpoint, e.g. `session/follow`, or `$events`. */
  endpoint: string
  /** The endpoint's arguments: dsh's `payload.args`, verbatim. */
  args: unknown
}

/**
 * Either direction: one item on an open stream. From the App it is uplink data
 * (most dsh streams read none); from the Bridle it is dsh's item, verbatim.
 */
export interface ItemFrame {
  t: 'item'
  sid: string
  value: unknown
}

/**
 * Either direction: the stream is finished. From the App it half-closes the
 * uplink; from the Bridle it is dsh's end, and the stream is gone.
 */
export interface EndFrame {
  t: 'end'
  sid: string
}

/** App to Bridle: stop a stream. No terminal frame follows. */
export interface CancelFrame {
  t: 'cancel'
  sid: string
}

/**
 * Bridle to App: the stream failed and is gone — dsh's error, verbatim, or one
 * the Bridle made (the connection to dsh dropped, an item too large to carry).
 */
export interface ErrorFrame {
  t: 'error'
  sid: string
  error: FrameError
}

/**
 * App to Bridle: where to knock when nobody is listening.
 *
 * The app posts its own notifications while it holds a tunnel, and that covers
 * the case where someone is already looking at their phone. It does not cover
 * the case this product exists for: the phone is in a pocket, iOS suspended the
 * process an hour ago, and the agent has just stopped to ask whether it may
 * delete something. Nothing local can fire, because nothing local is running.
 *
 * So the machine has to reach out, and the only thing that can wake a suspended
 * iOS app is APNs. The token travels inside the Noise channel — the Relay
 * carries it as ciphertext like everything else and learns it only at the
 * moment a push is actually sent, from the Bridle, one wake at a time.
 *
 * `token: null` means stop: someone turned notifications off in Settings, which
 * the app notices when it next comes to the foreground.
 *
 * No APNs environment travels with it. A token is minted against either the
 * development or the production host and is meaningless to the other, and an
 * earlier version had the app read `aps-environment` out of its own embedded
 * provisioning profile and pass the answer down through every layer. That is a
 * guess dressed as a fact — a Release build signed for development is a sandbox
 * token wearing a production badge — and Apple already answers the question by
 * refusing the wrong host with `BadDeviceToken`. The Relay tries both.
 */
export interface WakeFrame {
  t: 'wake'
  /** APNs device token, lowercase hex, or null to stop being woken. */
  token: string | null
}

/** App to Bridle: opening frame stating what the app expects. */
export interface HelloFrame {
  t: 'hello'
  version: number
  /** Human-readable client build, shown in `bridle status`. */
  client: string
}

/** Bridle to App: connection is live; describes the machine and its dsh. */
export interface ReadyFrame {
  t: 'ready'
  version: number
  /** Bridle package version. */
  bridle: string
  /** Display name of the paired machine. */
  machine: string
  /** Whether the Bridle holds a signed-in connection to dsh right now. */
  dshReachable: boolean
  /** Why not, when it does not. */
  detail?: string
  /** dsh's version, when known. */
  dsh?: string
  /**
   * Which harness this identity fronts (`url`) and where the identity lives
   * on disk (`home`). One machine can run several Bridles; this is how the
   * app tells them apart and how its rescue guidance names the right
   * `ROWEL_HOME`.
   */
  harness?: { url: string; home: string }
  /**
   * The machine itself: the account's home directory, which dsh 0.2 no longer
   * describes through a method (`host.describe` is gone) and the app needs as
   * the starting point of its folder picker.
   */
  host?: { home: string }
  /**
   * Where this machine can be dialled directly right now, best first.
   *
   * The pairing bundle's copy is frozen at pairing time; this one is current.
   * Present-but-empty means the direct listener is off, which is a reason to
   * *drop* stored addresses, not keep them.
   */
  direct?: string[]
}

/** Bridle to App: the connection to dsh went away or came back. */
export interface StatusFrame {
  t: 'status'
  dshReachable: boolean
  /** Operator-facing reason when unreachable. */
  detail?: string
}

/** Either direction: liveness probe. */
export interface PingFrame {
  t: 'ping'
  /** Echoed back verbatim. */
  nonce: string
}

/** Either direction: liveness answer. */
export interface PongFrame {
  t: 'pong'
  nonce: string
}

/** Bridle to App: a protocol-level refusal; the tunnel closes after it. */
export interface FaultFrame {
  t: 'fault'
  code: 'version' | 'unpaired' | 'internal' | 'busy'
  message: string
}

/** Frames the app may send. */
export type ClientFrame = HelloFrame | CallFrame | AbortFrame | OpenFrame | ItemFrame | EndFrame | CancelFrame | WakeFrame | PingFrame | PongFrame

/** Frames the Bridle may send. */
export type ServerFrame = ReadyFrame | ResultFrame | ItemFrame | EndFrame | ErrorFrame | StatusFrame | PingFrame | PongFrame | FaultFrame

/** Every tunnel frame. */
export type TunnelFrame = ClientFrame | ServerFrame

/**
 * Encode one frame for the Noise channel.
 * @param frame - the frame to send.
 * @returns UTF-8 JSON bytes.
 */
export function encodeFrame(frame: TunnelFrame): Buffer {
  return Buffer.from(JSON.stringify(frame), 'utf8')
}

/**
 * Decode one frame received from the Noise channel.
 * @param bytes - the decrypted frame body.
 * @returns the parsed frame.
 * @throws {@link Error} when the body is not a JSON object carrying a string `t`.
 */
export function decodeFrame(bytes: Buffer): TunnelFrame {
  let parsed: unknown
  try {
    parsed = JSON.parse(bytes.toString('utf8'))
  } catch {
    throw new Error('tunnel frame is not JSON')
  }
  if (typeof parsed !== 'object' || parsed === null || typeof (parsed as { t?: unknown }).t !== 'string') {
    throw new Error('tunnel frame has no type tag')
  }
  return parsed as TunnelFrame
}
