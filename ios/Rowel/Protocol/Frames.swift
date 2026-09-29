/// Tunnel frames: the application protocol carried inside the Noise channel.
///
/// The Swift twin of `protocol/src/frames.ts`. One tunnel multiplexes everything
/// — unary RPC, both harness downlinks, cancellation — so the phone holds exactly
/// one socket no matter how much is going on.
///
/// Outbound frames state their key order (see `TunnelFrame`) rather than relying
/// on `JSONEncoder`, which has none to give.

import Foundation

/// Versions this build can speak, preferred first.
///
/// A set rather than a number, because the two ends update independently: this
/// app sits in a review queue while the Bridle is one `npm install` away, so
/// after release version skew is the normal case. Both ends offer what they can
/// speak and the machine picks the highest they share.
public let tunnelVersions: [Int] = [1]

/// The newest version this build speaks; what it reports about itself.
public let tunnelVersion = tunnelVersions[0]

/// Noise prologue both ends mix in before the first handshake message.
///
/// Deliberately carries no version. An earlier design put one here, which made
/// a mismatch fail *inside* the handshake — before any channel exists, so the
/// machine's refusal could not be sent and this end could not tell version skew
/// from a wrong machine key from tampering. The version is negotiated in the
/// handshake payload instead.
public let tunnelPrologue = Data("rowel-tunnel".utf8)

/// Which harness downlink an event frame came from.
public enum StreamName: String, Codable, Sendable {
    /// Every session's events, aggregated.
    case mux
    /// Machine-level events: sessions added and removed, running flips, workspaces.
    case host
}

/// The encoder both ends agree on: no slash escaping, no pretty printing.
///
/// `JSONEncoder` escapes `/` by default and Node's `JSON.stringify` does not, so
/// without this a Typert Remote method like `goals/create` would go out as
/// `goals\/create` — still valid JSON, still routed correctly, but not the same
/// bytes, and the parity tests would be lying about agreement.
///
/// `sortedKeys` applies to the payloads nested inside a frame. A `JSONValue`
/// object is a Swift dictionary and has no order of its own, and Swift seeds its
/// string hashing per process, so without this the same payload serialises
/// differently between launches. Sorted is arbitrary but stable, which is what
/// makes a captured frame reproducible.
let tunnelEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
    return encoder
}()

/// A frame written with its keys in a stated order.
///
/// `JSONEncoder` backs a keyed container with a dictionary, so a `Codable`
/// struct's properties come out in whatever order hashing produced — not
/// declaration order, and not the same order twice. Node's `JSON.stringify`
/// emits insertion order, and the cross-implementation vectors compare bytes, so
/// the order has to be written down rather than inherited from a container that
/// does not have one.
///
/// Nothing here is signed, so a reordered frame would still be understood. The
/// point is that byte agreement is a property the two implementations can
/// actually be tested against, and a test that cannot fail is not a test.
protocol TunnelFrame: Sendable {
    /// The frame's members, in wire order. A `nil` value is omitted, matching
    /// `JSON.stringify` dropping `undefined`.
    var members: [(String, JSONValue?)] { get }
}

extension TunnelFrame {
    func encoded() throws -> Data { try orderedJSON(members) }
}

/// Serialise a JSON object with the given key order, dropping absent members.
func orderedJSON(_ members: [(String, JSONValue?)]) throws -> Data {
    var bytes = Data([UInt8(ascii: "{")])
    var first = true
    for (key, value) in members {
        guard let value else { continue }
        if !first { bytes.append(UInt8(ascii: ",")) }
        first = false
        bytes.append(try tunnelEncoder.encode(JSONValue.string(key)))
        bytes.append(UInt8(ascii: ":"))
        bytes.append(try tunnelEncoder.encode(value))
    }
    bytes.append(UInt8(ascii: "}"))
    return bytes
}

// MARK: - App to Bridle

/// Invoke one unary harness method (`POST /api/<method>` on the far side).
public struct RequestFrame: TunnelFrame {
    public let t = "req"
    /// App-minted correlation id, unique per tunnel.
    public let id: String
    /// Method path segment, e.g. `session.prompt` or `goals/create`.
    public let method: String
    /// The request payload (`{ args }` for Typert Remote methods).
    public let payload: JSONValue

    public init(id: String, method: String, payload: JSONValue) {
        self.id = id
        self.method = method
        self.payload = payload
    }

    var members: [(String, JSONValue?)] {
        [("t", .string(t)), ("id", .string(id)), ("method", .string(method)), ("payload", payload)]
    }
}

/// Abandon an in-flight request; the Bridle aborts its fetch to the harness.
public struct CancelFrame: TunnelFrame {
    public let t = "cancel"
    public let id: String

    public init(id: String) {
        self.id = id
    }

    var members: [(String, JSONValue?)] {
        [("t", .string(t)), ("id", .string(id))]
    }
}

/// Answer an approval or a question (`POST /api/respond` on the far side).
public struct RespondFrame: TunnelFrame {
    public let t = "respond"
    public let id: String
    /// The harness `client-response` message, verbatim.
    public let message: JSONValue

    public init(id: String, message: JSONValue) {
        self.id = id
        self.message = message
    }

    var members: [(String, JSONValue?)] {
        [("t", .string(t)), ("id", .string(id)), ("message", message)]
    }
}

/// After a reconnect, replay everything past `since`.
public struct ResumeFrame: TunnelFrame {
    public let t = "resume"
    /// Highest sequence the app already holds; `0` asks for a fresh subscription.
    public let since: Int
    /// The `ready.epoch` of the connection `since` was counted on, so a Bridle
    /// that restarted — and restarted its numbering — answers `resync`.
    public let epoch: String?

    public init(since: Int, epoch: String? = nil) {
        self.since = since
        self.epoch = epoch
    }

    var members: [(String, JSONValue?)] {
        [("t", .string(t)), ("since", .number(Double(since))), ("epoch", epoch.map(JSONValue.string))]
    }
}

/// Where to knock when this app is not running.
///
/// The notifications this app posts itself only fire while it holds a tunnel,
/// and it usually does not: iOS suspends a backgrounded app within minutes and
/// the socket goes with it. Everything the agent asks after that reaches a
/// machine that is waiting on someone who was never told — which is the case
/// the app exists for, since being elsewhere is the point.
///
/// The token goes to the machine, inside the Noise channel, and no further: the
/// Relay is handed it one wake at a time, at the moment a push is sent, and is
/// never told what the push is about. A `nil` token withdraws it, which is what
/// notifications being switched off in Settings looks like from here.
///
/// No APNs environment travels with it. Which host minted a token is Apple's
/// question to answer — it refuses the wrong one with `BadDeviceToken` — and an
/// earlier version had this app read `aps-environment` out of its own
/// provisioning profile and pass a guess down through every layer.
///
/// The `null` is written out rather than omitted. An absent key means "no
/// change"; a present null means "stop ringing me", and dropping it the way an
/// optional normally would leaves a machine ringing a phone that asked to be
/// left alone. The cross-implementation vectors carry both shapes for exactly
/// this reason.
public struct WakeFrame: TunnelFrame {
    public let t = "wake"
    /// APNs device token as lowercase hex, or nil to stop being woken.
    public let token: String?

    public init(token: String?) {
        self.token = token
    }

    var members: [(String, JSONValue?)] {
        [("t", .string(t)), ("token", token.map { JSONValue.string($0) } ?? .null)]
    }
}

/// Liveness question, app to Bridle. The Bridle answers with a pong carrying
/// the same nonce — any frame at all proves the carrier, but asking forces an
/// answer out of a connection that would otherwise be silently dead for the
/// whole of the watchdog's patience.
public struct PingFrame: TunnelFrame {
    public let t = "ping"
    public let nonce: String

    public init(nonce: String) {
        self.nonce = nonce
    }

    var members: [(String, JSONValue?)] {
        [("t", .string(t)), ("nonce", .string(nonce))]
    }
}

/// Liveness answer.
public struct PongFrame: TunnelFrame {
    public let t = "pong"
    public let nonce: String

    public init(nonce: String) {
        self.nonce = nonce
    }

    var members: [(String, JSONValue?)] {
        [("t", .string(t)), ("nonce", .string(nonce))]
    }
}

/// What the app states inside handshake message one.
///
/// The token is present only while pairing. A device that is already known sends
/// none, so a stolen pairing QR is worth exactly one connection attempt.
public struct HandshakeRequest: TunnelFrame {
    /// Every version this build can speak, preferred first.
    public let versions: [Int] = tunnelVersions
    public let name: String
    public let client: String
    public let token: String?

    public init(name: String, client: String, token: String?) {
        self.name = name
        self.client = client
        self.token = token
    }

    var members: [(String, JSONValue?)] {
        [
            ("versions", .array(versions.map { .number(Double($0)) })),
            ("name", .string(name)),
            ("client", .string(client)),
            ("token", token.map(JSONValue.string)),
        ]
    }
}

/// What the Bridle states back inside handshake message two.
public struct HandshakeReply: Codable, Sendable {
    public let ok: Bool
    /// The version both ends will speak. Present when `ok`.
    public let version: Int?
    /// Refusal reason when `ok` is false: `version`, `unpaired`, `internal`, or
    /// `pending` — a short-code claim waiting for the Mac, the one that is not final.
    public let reason: String?
    /// What the machine can speak, when it refused for `version`. Lets this end
    /// say *which* side is the old one rather than "something went wrong".
    public let supported: [Int]?
    /// Display name of the machine.
    public let machine: String?
    /// Bridle version string.
    public let bridle: String?

    /// Which end needs updating, for a refusal this end can explain.
    ///
    /// If the machine speaks something newer than anything we do, we are behind.
    /// Otherwise it is.
    public var weAreTheOldEnd: Bool {
        guard let supported, let theirBest = supported.max(), let ourBest = tunnelVersions.max() else { return false }
        return theirBest > ourBest
    }
}

// MARK: - Bridle to App

/// A harness call that failed, or a tunnel that could not carry it.
public struct CallError: Error, Equatable, Sendable {
    public let code: String
    public let message: String
    public let details: JSONValue

    public init(code: String, message: String, details: JSONValue = .null) {
        self.code = code
        self.message = message
        self.details = details
    }

    /// Whether retrying the same call could plausibly succeed.
    public var isTransient: Bool {
        ["disconnected", "timeout", "internal", "agent-busy"].contains(code)
    }
}

extension CallError: LocalizedError {
    public var errorDescription: String? { message }
}

/// Which harness a Bridle identity fronts, and where the identity lives.
///
/// One Mac can run several Bridles; until the app knows which one it is
/// talking to, every offline screen says the same name and every rescue
/// command defaults to the wrong home. Optional end to end: a Bridle too old
/// to send it costs the app a label, nothing more.
public struct HarnessInfo: Equatable, Sendable {
    /// The dsh address this identity points at, e.g. `http://127.0.0.1:3081`.
    public let url: String
    /// The `ROWEL_HOME` the identity lives in on the Mac.
    public let home: String

    public init(url: String, home: String) {
        self.url = url
        self.home = home
    }

    /// The port, which is how a person tells instances apart.
    public var port: String? {
        guard let colon = url.lastIndex(of: ":"), colon != url.startIndex else { return nil }
        let digits = url[url.index(after: colon)...].prefix(while: \.isNumber)
        return digits.isEmpty ? nil : String(digits)
    }
}

/// Connection is live; describes the machine and its harness.
public struct ReadyFrame: Sendable {
    public let version: Int
    public let bridle: String
    public let machine: String
    public let dshReachable: Bool
    /// Which harness, and where the identity lives. `nil` from an older Bridle.
    public let harness: HarnessInfo?
    /// The harness `host.describe` value when reachable.
    public let host: JSONValue?
    /// Where this machine can be dialled directly right now, best first.
    ///
    /// `nil` from a Bridle too old to send it — which must leave the app's
    /// stored addresses alone. `[]` is different and deliberate: it means the
    /// direct listener is off, and keeping stale addresses around would have
    /// the app dialling a listener the operator turned off.
    public let direct: [String]?
    /// Highest event sequence the Bridle has produced.
    public let seq: Int
    /// Which Bridle process's numbering `seq` belongs to. `nil` from an older Bridle.
    public var epoch: String? = nil
}

/// One downlink frame, tagged with a tunnel-level sequence.
public struct EventFrame: Sendable {
    public let seq: Int
    public let stream: StreamName
    /// The harness `server-request` frame, verbatim.
    public let frame: JSONValue
}

/// Everything the Bridle can send.
public enum ServerFrame: Sendable {
    case ready(ReadyFrame)
    case response(id: String, result: Result<JSONValue, CallError>)
    case event(EventFrame)
    /// Events were lost to this app — the replay buffer no longer reaches back,
    /// the Bridle restarted, or an event was too large to carry. Refetch state.
    case resync(from: Int)
    /// The local harness went away or came back.
    case status(reachable: Bool, detail: String?)
    case ping(nonce: String)
    case pong(nonce: String)
    /// A protocol-level refusal; the tunnel closes after it.
    case fault(code: String, message: String)
    /// A frame type this build does not know. Tolerated on purpose.
    case unknown(tag: String)
}

/// A frame that arrived malformed.
public struct FrameError: Error, LocalizedError, Equatable {
    public let reason: String
    public var errorDescription: String? { reason }
}

public extension ServerFrame {
    /// Parse one decrypted frame body.
    static func decode(_ bytes: Data) throws -> ServerFrame {
        guard let value = try? JSONValue(data: bytes) else { throw FrameError(reason: "tunnel frame is not JSON") }
        guard let tag = value["t"]?.stringValue else { throw FrameError(reason: "tunnel frame has no type tag") }
        switch tag {
        case "ready":
            return .ready(ReadyFrame(
                version: value["version"]?.intValue ?? tunnelVersion,
                bridle: value["bridle"]?.stringValue ?? "unknown",
                machine: value["machine"]?.stringValue ?? "a computer",
                dshReachable: value["dshReachable"]?.boolValue ?? false,
                harness: (value["harness"]?["url"]?.stringValue).map { url in
                    HarnessInfo(url: url, home: value["harness"]?["home"]?.stringValue ?? "")
                },
                host: value["host"],
                direct: value["direct"]?.arrayValue.map { $0.compactMap(\.stringValue) },
                seq: value["seq"]?.intValue ?? 0,
                epoch: value["epoch"]?.stringValue
            ))
        case "res":
            guard let id = value["id"]?.stringValue else { throw FrameError(reason: "response has no id") }
            let result = value["result"]
            if result?["ok"]?.boolValue == true {
                return .response(id: id, result: .success(result?["value"] ?? .null))
            }
            let error = result?["error"]
            return .response(id: id, result: .failure(CallError(
                code: error?["code"]?.stringValue ?? "internal",
                message: error?["message"]?.stringValue ?? "the machine reported a failure",
                details: error?["details"] ?? .null
            )))
        case "ev":
            guard let seq = value["seq"]?.intValue else { throw FrameError(reason: "event has no sequence") }
            let stream = StreamName(rawValue: value["stream"]?.stringValue ?? "mux") ?? .mux
            return .event(EventFrame(seq: seq, stream: stream, frame: value["frame"] ?? .null))
        case "resync":
            return .resync(from: value["from"]?.intValue ?? 0)
        case "status":
            return .status(reachable: value["dshReachable"]?.boolValue ?? false, detail: value["detail"]?.stringValue)
        case "ping":
            return .ping(nonce: value["nonce"]?.stringValue ?? "")
        case "pong":
            return .pong(nonce: value["nonce"]?.stringValue ?? "")
        case "fault":
            return .fault(
                code: value["code"]?.stringValue ?? "internal",
                message: value["message"]?.stringValue ?? "the machine refused the connection"
            )
        default:
            return .unknown(tag: tag)
        }
    }
}
