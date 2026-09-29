/**
 * Tunnel frames: the application protocol carried inside the Noise channel.
 * One tunnel multiplexes every dsh interaction — unary RPC, the two event
 * downlinks, and cancellation — so the phone holds exactly one socket.
 *
 * Frames are JSON. The dsh API is JSON end to end (attachments ride as base64
 * inside it), so a binary framing would buy nothing and cost debuggability.
 */

/** Protocol version mixed into the Noise prologue; a mismatch aborts the handshake. */
export const TUNNEL_VERSION = 1

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

export const TUNNEL_VERSIONS: readonly number[] = [1]

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

/** Which dsh downlink an event frame came from. */
export type StreamName = 'mux' | 'host'

/** App to Bridle: invoke one unary dsh method (`POST /api/<method>`). */
export interface RequestFrame {
  t: 'req'
  /** App-minted correlation id, unique per tunnel. */
  id: string
  /** dsh method path segment, e.g. `session.prompt` or `goals/create`. */
  method: string
  /** The dsh request payload (`{ args }` for Typert Remote methods). */
  payload: unknown
}

/** Bridle to App: the result of one {@link RequestFrame}. */
export interface ResponseFrame {
  t: 'res'
  id: string
  /** The dsh `server-response.result`, or a locally synthesized failure. */
  result: { ok: true; value: unknown } | { ok: false; error: { code: string; message: string; details: unknown } }
}

/** App to Bridle: abandon an in-flight request (maps to aborting the dsh fetch). */
export interface CancelFrame {
  t: 'cancel'
  id: string
}

/** App to Bridle: answer an approval or question (`POST /api/respond`). */
export interface RespondFrame {
  t: 'respond'
  id: string
  /** The dsh `client-response` message, verbatim. */
  message: unknown
}

/** Bridle to App: one downlink frame, tagged with a tunnel-level sequence. */
export interface EventFrame {
  t: 'ev'
  /** Monotonic per-tunnel sequence used by {@link ResumeFrame}. */
  seq: number
  stream: StreamName
  /** The dsh `server-request` frame, verbatim. */
  frame: unknown
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

/** App to Bridle: after a reconnect, replay everything past `since`. */
export interface ResumeFrame {
  t: 'resume'
  /** Highest sequence the app already has; `0` requests a fresh subscription. */
  since: number
  /**
   * The `ready.epoch` of the connection `since` was counted on. A Bridle that
   * restarted has a different one and answers `resync`. Omitted on the first
   * connection, and by apps that predate it.
   */
  epoch?: string
}

/**
 * Bridle to App: events were lost to this app — the replay buffer no longer
 * reaches `since`, the Bridle restarted, or an event was too large to carry —
 * so refetch state. Events continue after `from`.
 */
export interface ResyncFrame {
  t: 'resync'
  /** Events resume after this sequence; the app keeps it as its high-water mark. */
  from: number
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
  /** Whether the local dsh is reachable right now. */
  dshReachable: boolean
  /**
   * Which harness this identity fronts (`url`) and where the identity lives
   * on disk (`home`). One machine can run several Bridles; this is how the
   * app tells them apart and how its rescue guidance names the right
   * `ROWEL_HOME`. Optional: an older Bridle not sending it costs a label.
   */
  harness?: { url: string; home: string }
  /** dsh `host.describe` value when reachable. */
  host?: unknown
  /**
   * Where this machine can be dialled directly right now, best first.
   *
   * The pairing bundle's copy is frozen at pairing time; this one is current.
   * Absent from Bridles that predate it — a client must then keep whatever
   * addresses it has. Present-but-empty means the direct listener is off,
   * which is a reason to *drop* stored addresses, not keep them.
   */
  direct?: string[]
  /** Highest event sequence the Bridle has produced. */
  seq: number
  /**
   * Identifies this Bridle process's event numbering, which restarts with
   * every process. The app echoes it in its next `resume`.
   */
  epoch?: string
}

/** Bridle to App: the local dsh went away or came back. */
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
export type ClientFrame = HelloFrame | RequestFrame | CancelFrame | RespondFrame | ResumeFrame | WakeFrame | PingFrame | PongFrame

/** Frames the Bridle may send. */
export type ServerFrame = ReadyFrame | ResponseFrame | EventFrame | ResyncFrame | StatusFrame | PingFrame | PongFrame | FaultFrame

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
