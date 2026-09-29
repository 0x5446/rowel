/// An in-memory Bridle, so the tunnel's timing faults can be provoked.
///
/// Everything that has actually gone wrong with this connection in the field is
/// a fault of timing rather than of parsing: a socket that stops delivering
/// without ever closing, a carrier retired underneath a read already in flight,
/// a local address that connects and then dies. None of those can be arranged
/// against a real WebSocket — you cannot ask a network to go quiet on cue — so
/// the carrier is a pair of in-memory pipes and the machine at the other end is
/// the code below.
///
/// It speaks the real protocol. `NoiseResponder` is the app's own, the frames
/// are the app's own encoders, and the channel is a real `SecureChannel`, so a
/// test that passes here is not passing against a mock of the app's beliefs.
/// Only the transport is fake, which is the one part being tested.

import Foundation
@testable import Rowel

// MARK: - Carrier

/// One end of a pipe. Reads what the other end writes.
final class LoopbackCarrier: Carrying, @unchecked Sendable {
    private let lock = NSLock()
    private var inbox: [Data] = []
    private var waiter: CheckedContinuation<Data, Error>?
    private var failure: Error?
    /// Set to stop delivering without closing — the failure this whole file
    /// exists to reproduce.
    private var muted = false
    /// Whether a read ignores task cancellation, as `URLSessionWebSocketTask`
    /// was observed to when writing to an address that no longer exists.
    ///
    /// On by default for a black hole and only there. A fake that is politely
    /// cancellable cannot reproduce the bug that mattered — a losing racer
    /// holding the whole dial for three minutes — and a test written against
    /// the polite version passes whether or not the code is fixed.
    var ignoresCancellation = false

    /// The other end. Weak on one side would break the pair; both are held by
    /// the harness, which outlives them.
    var peer: LoopbackCarrier?
    private(set) var closeReason: String?

    func send(_ bytes: Data) async throws {
        if let failure = lock.withLock({ self.failure }) { throw failure }
        peer?.deliver(bytes)
    }

    /// Honours cancellation, which is not a nicety here.
    ///
    /// A racer that loses is cancelled, and both `withTimeout` and the dial's
    /// task group wait for every child before returning. A read that ignores
    /// cancellation therefore does not merely leak — it hangs the dial that
    /// started it, and the first version of this file deadlocked every test
    /// with an unreachable address in it. `URLSessionWebSocketTask` does honour
    /// cancellation, so this is fidelity rather than convenience.
    func receive() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let failure {
                    lock.unlock()
                    continuation.resume(throwing: failure)
                    return
                }
                if !inbox.isEmpty {
                    let next = inbox.removeFirst()
                    lock.unlock()
                    continuation.resume(returning: next)
                    return
                }
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiter = continuation
                lock.unlock()
            }
        } onCancel: {
            guard !ignoresCancellation else { return }
            lock.lock()
            let pending = waiter
            waiter = nil
            lock.unlock()
            pending?.resume(throwing: CancellationError())
        }
    }

    func close(_ reason: String) {
        let pending: CheckedContinuation<Data, Error>?
        lock.lock()
        if closeReason == nil { closeReason = reason }
        if failure == nil { failure = CarrierError(reason: reason, closeCode: nil) }
        pending = waiter
        waiter = nil
        let error = failure
        lock.unlock()
        if let pending, let error { pending.resume(throwing: error) }
    }

    /// Stop passing anything on, without telling anyone. What a cellular
    /// handover does.
    func goQuiet() {
        lock.withLock { muted = true }
    }

    func deliver(_ bytes: Data) {
        let pending: CheckedContinuation<Data, Error>?
        lock.lock()
        if muted || failure != nil {
            lock.unlock()
            return
        }
        if let waiter {
            pending = waiter
            self.waiter = nil
            lock.unlock()
            pending?.resume(returning: bytes)
            return
        }
        inbox.append(bytes)
        pending = nil
        lock.unlock()
        _ = pending
    }

    /// A connected pair, app end first.
    static func pair() -> (app: LoopbackCarrier, machine: LoopbackCarrier) {
        let app = LoopbackCarrier()
        let machine = LoopbackCarrier()
        app.peer = machine
        machine.peer = app
        return (app, machine)
    }
}

// MARK: - Machine

/// A Bridle that exists only in this process.
actor FakeBridle {
    let staticKeys: StaticKeyPair
    let name: String
    /// Every carrier this machine has served, oldest first, so a test can ask
    /// which sockets were opened and in what order.
    private(set) var served: [LoopbackCarrier] = []
    private(set) var resumedFrom: [Int] = []
    /// The `epoch` each resume carried, in order; nil when it carried none.
    private(set) var resumedEpochs: [String?] = []
    /// This process's event numbering, as the ready frame names it.
    let epoch = UUID().uuidString
    private(set) var handshakes = 0
    /// Every `wake` frame received, oldest first; nil for a withdrawal.
    private(set) var wakes: [String?] = []

    private var channels: [ObjectIdentifier: SecureChannel] = [:]
    private var head = 0
    /// Handshakes still to be refused, and with what reason.
    private var refusals: [String] = []

    /// Answer the next `times` handshakes with `pending`, as a Bridle does for
    /// a short-code claim until the person at the Mac accepts it.
    func holdForApproval(times: Int) {
        refuse(times: times, reason: "pending")
    }

    /// Refuse the next `times` handshakes with `reason`.
    func refuse(times: Int, reason: String) {
        refusals = Array(repeating: reason, count: times)
    }

    /// What the ready frame advertises as this machine's current addresses.
    let direct: [String]

    init(name: String = "a-mac", staticKeys: StaticKeyPair = .generate(), direct: [String] = []) {
        self.name = name
        self.staticKeys = staticKeys
        self.direct = direct
    }

    /// Accept a handshake and then read whatever the app sends.
    func serve(_ carrier: LoopbackCarrier) async {
        served.append(carrier)
        do {
            let responder = NoiseResponder(staticKeys: staticKeys, prologue: tunnelPrologue)
            let hello = try await carrier.receive()
            _ = try responder.readMessage(hello)
            if !refusals.isEmpty {
                let reason = refusals.removeFirst()
                let refusal = try JSONEncoder().encode(HandshakeReply(
                    ok: false, version: nil, reason: reason, supported: nil, machine: nil, bridle: nil
                ))
                try await carrier.send(try responder.writeMessage(refusal).message)
                carrier.close(reason)
                return
            }
            let reply = try JSONEncoder().encode(HandshakeReply(
                ok: true, version: tunnelVersion, reason: nil, supported: nil, machine: name, bridle: "fake/0"
            ))
            let (message, channel) = try responder.writeMessage(reply)
            try await carrier.send(message)
            channels[ObjectIdentifier(carrier)] = channel
            handshakes += 1
            try await push(to: carrier, json: [
                "t": .string("ready"),
                "version": .number(Double(tunnelVersion)),
                "bridle": .string("fake/0"),
                "machine": .string(name),
                "dshReachable": .bool(true),
                "direct": .array(direct.map(JSONValue.string)),
                "seq": .number(Double(head)),
                "epoch": .string(epoch),
            ])
            while true {
                let bytes = try await carrier.receive()
                guard let channel = channels[ObjectIdentifier(carrier)] else { return }
                let plain = try channel.decrypt(bytes)
                guard let value = try? JSONValue(data: plain) else { continue }
                switch value["t"]?.stringValue {
                case "resume":
                    resumedFrom.append(value["since"]?.intValue ?? 0)
                    resumedEpochs.append(value["epoch"]?.stringValue)
                case "wake":
                    wakes.append(value["token"]?.stringValue)
                case "ping":
                    // As the real Bridle does — the app's foreground probe
                    // counts on this answer, and a fake that swallows pings
                    // fails healthy connections instead of dead ones.
                    try await push(to: carrier, json: [
                        "t": .string("pong"),
                        "nonce": value["nonce"] ?? .string(""),
                    ])
                default:
                    break
                }
            }
        } catch {
            // A closed carrier ends the loop; that is the normal exit.
        }
    }

    /// Send one event frame on the most recent carrier.
    func emit(seq: Int, to carrier: LoopbackCarrier) async {
        head = max(head, seq)
        try? await push(to: carrier, json: [
            "t": .string("ev"),
            "seq": .number(Double(seq)),
            "stream": .string("mux"),
            "frame": .object(["type": .string("noop")]),
        ])
    }

    private func push(to carrier: LoopbackCarrier, json: [String: JSONValue]) async throws {
        guard let channel = channels[ObjectIdentifier(carrier)] else { return }
        let body = try JSONValue.object(json).encoded()
        try await carrier.send(try channel.encrypt(body))
    }

    /// A bundle pointing at this machine, with the given addresses.
    nonisolated func bundle(direct: [String]?, relay: String = "wss://relay.test") -> PairingBundle {
        PairingBundle(
            relay: relay,
            direct: direct,
            device: "device",
            key: staticKeys.publicKey.base64urlString,
            token: "token",
            name: name
        )
    }
}

// MARK: - Switchboard

/// Routes the tunnel's dials to fake machines, and records them.
///
/// A test says "this URL answers, that one hangs" and gets an opener it can
/// hand to `Tunnel`.
final class TestSwitchboard: @unchecked Sendable {
    /// How one address behaves.
    enum Behaviour {
        /// A machine answers.
        case machine(FakeBridle)
        /// Accepts the connection and never says anything, like an address that
        /// routes nowhere. This is what a LAN address does from cellular.
        case blackHole
    }

    private let lock = NSLock()
    private var routes: [String: Behaviour] = [:]
    private var dialled: [String] = []
    /// The app-side carrier handed out for each address, latest last.
    private var handed: [(host: String, carrier: LoopbackCarrier)] = []

    func route(_ url: String, to behaviour: Behaviour) {
        lock.withLock { routes[url] = behaviour }
    }

    var dialledAddresses: [String] { lock.withLock { dialled } }

    func carrier(for host: String) -> LoopbackCarrier? {
        lock.withLock { handed.last { $0.host == host }?.carrier }
    }

    var opener: CarrierOpener {
        { [self] url, _ in
            let key = "\(url.host ?? "?"):\(url.port ?? 0)"
            let behaviour = lock.withLock {
                dialled.append(key)
                return routes[key]
            }
            let (app, machine) = LoopbackCarrier.pair()
            lock.withLock { handed.append((key, app)) }
            switch behaviour {
            case .machine(let bridle):
                Task { await bridle.serve(machine) }
            case .blackHole, .none:
                // Deaf to cancellation as well as to messages: the two
                // together are what a dead address actually behaves like.
                app.ignoresCancellation = true
            }
            return app
        }
    }
}
