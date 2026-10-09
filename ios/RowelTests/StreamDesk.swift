/// dsh's streams, played by the test.
///
/// Since tunnel version 2 everything live reaches `MachineSession` through
/// `HarnessTransport.open` — `$events`, `workspace/follow`, `session/control`,
/// one `session/follow` per conversation. A transport that owns a desk hands
/// out its streams, and the test writes into them what dsh would have said.

import Foundation
@testable import Rowel

final class StreamDesk: @unchecked Sendable {
    private struct Opened {
        let endpoint: String
        let args: JSONValue
        let continuation: AsyncThrowingStream<JSONValue, Error>.Continuation
    }

    private let lock = NSLock()
    private var opened: [Opened] = []
    private var ended: [String] = []

    func open(_ endpoint: String, _ args: JSONValue) -> TunnelStream {
        var continuation: AsyncThrowingStream<JSONValue, Error>.Continuation!
        let items = AsyncThrowingStream<JSONValue, Error>(bufferingPolicy: .unbounded) { continuation = $0 }
        let sid = lock.withLock {
            opened.append(Opened(endpoint: endpoint, args: args, continuation: continuation))
            return "\(endpoint)#\(opened.count)"
        }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { self.ended.append(sid) }
        }
        return TunnelStream(sid: sid, items: items, cancel: { [continuation] in continuation?.finish() })
    }

    /// Whether the latest `session/follow` for `session` has stopped — its
    /// reader let go, or it was ended.
    func followEnded(_ session: String) -> Bool {
        lock.withLock {
            guard let index = opened.lastIndex(where: {
                $0.endpoint == "session/follow" && $0.args.path("request", "address", "sessionId")?.stringValue == session
            }) else { return false }
            return ended.contains("session/follow#\(index + 1)")
        }
    }

    /// How many times `endpoint` has been opened.
    func count(_ endpoint: String) -> Int {
        lock.withLock { opened.filter { $0.endpoint == endpoint }.count }
    }

    /// The arguments of every open of `endpoint`, oldest first.
    func args(_ endpoint: String) -> [JSONValue] {
        lock.withLock { opened.filter { $0.endpoint == endpoint }.map(\.args) }
    }

    /// Deliver one item on the latest stream opened for `endpoint` — for
    /// `session/follow`, the latest one for that session.
    func send(_ endpoint: String, session: String? = nil, _ item: JSONValue) {
        latest(endpoint, session: session)?.continuation.yield(item)
    }

    /// End the latest stream for `endpoint` with a failure.
    func fail(_ endpoint: String, session: String? = nil, code: String) {
        latest(endpoint, session: session)?.continuation.finish(throwing: CallError(code: code, message: code))
    }

    /// End every stream with `disconnected`, as a dropped tunnel does.
    func disconnectAll() {
        let all = lock.withLock { opened }
        for entry in all { entry.continuation.finish(throwing: CallError(code: "disconnected", message: "disconnected")) }
    }

    private func latest(_ endpoint: String, session: String?) -> Opened? {
        lock.withLock {
            opened.last { entry in
                entry.endpoint == endpoint
                    && (session == nil || entry.args.path("request", "address", "sessionId")?.stringValue == session)
            }
        }
    }
}

/// A transport that only answers calls: every stream it is asked for ends at
/// once. A protocol of its own rather than a default on `HarnessTransport`,
/// which `Tunnel` conforms to — a default there would shadow the tunnel's own
/// `open` in every test that calls it.
protocol CallOnlyTransport: HarnessTransport {}

extension CallOnlyTransport {
    func open(_ endpoint: String, _ args: JSONValue) async -> TunnelStream {
        TunnelStream(sid: endpoint, items: AsyncThrowingStream { $0.finish() }, cancel: {})
    }
}

extension ReadyFrame {
    /// A handshake from a Bridle whose dsh is up.
    static func test(dshReachable: Bool = true, home: String? = "/Users/someone") -> ReadyFrame {
        ReadyFrame(version: 2, bridle: "0.2.0", machine: "Test Mac", dshReachable: dshReachable, dsh: "0.2.0", harness: nil, home: home, direct: nil)
    }
}

/// A `session/follow` snapshot, from records.
func snapshot(_ events: [JSONValue], hasMore: Bool = false, projections: JSONValue = .emptyObject) -> JSONValue {
    .object([
        "type": .string("snapshot"),
        "cursor": .number(Double(events.last?["seq"]?.intValue ?? -1)),
        "records": .array(events.map { .object(["type": .string("event"), "event": $0]) }),
        "hasMore": .bool(hasMore),
        "projections": .object(["asOfSeq": .number(Double(events.last?["seq"]?.intValue ?? 0)), "values": projections]),
        "assistantStream": .object(["revision": .number(0)]),
    ])
}

/// A `session/follow` event item.
func eventItem(_ event: JSONValue) -> JSONValue {
    .object(["type": .string("event"), "event": event])
}

/// A `session/follow` assistant-stream item.
func streamItem(_ frame: JSONValue) -> JSONValue {
    .object(["type": .string("assistant-stream"), "frame": frame])
}

/// A recorded dsh 0.2 answer from `Fixtures/dsh-0.2`.
func fixture(_ name: String) throws -> JSONValue {
    guard let url = Bundle(for: StreamDesk.self).url(forResource: name, withExtension: "json") else {
        throw CallError(code: "missing-fixture", message: "no fixture \(name).json in the test bundle")
    }
    return try JSONValue(data: Data(contentsOf: url))
}

/// An `assistant-stream` frame that starts an attempt.
func streamStart(attempt: String = "attempt", turn: Int, step: Int) -> JSONValue {
    .object([
        "type": .string("start"), "attemptId": .string(attempt),
        "turn": .number(Double(turn)), "step": .number(Double(step)), "revision": 1, "startedAfterSeq": 0,
    ])
}

/// An `assistant-stream` frame carrying one delta of an attempt.
func streamChunk(attempt: String = "attempt", kind: String = "text-delta", _ text: String) -> JSONValue {
    .object([
        "type": .string("chunk"), "attemptId": .string(attempt), "index": 0, "time": 1_700_000_000_000,
        "chunk": .object(["type": .string(kind), "index": 0, "text": .string(text)]),
    ])
}
