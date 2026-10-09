/// One encrypted tunnel to one machine.
///
/// Everything the app does with a machine goes through here: unary calls, both
/// harness downlinks, approvals. One socket, because a phone that holds four is
/// a phone that reconnects four times every time the radio blinks.
///
/// The way it picks a path is Happy Eyeballs — RFC 8305, by Apple's own
/// Schinazi and Pauly — applied to endpoints rather than to address families:
/// dial the candidates concurrently, stagger their starts to express a
/// preference, take the first that answers, cancel the rest. The spec covers
/// IPv6 against IPv4 for one host and an attempt to generalise it to other
/// kinds of choice was abandoned, so this borrows the shape rather than
/// implementing the document. The staggering constant comes from it, though;
/// see `TunnelTimings.relayHeadStart`.
///
/// The full answer to "which of several paths" is ICE (RFC 8445), and it is
/// the wrong tool here for a reason the spec states itself: candidate
/// gathering, priority formulas, controlling and controlled roles and
/// nomination all exist because two peers behind NATs are unlikely to reach
/// each other directly. Nothing here punches a hole. The relay is a rendezvous
/// that always works, not a last resort, so there are exactly two candidate
/// kinds and no negotiation to run. Below this layer, URLSession already does
/// the address-family race that RFC 8305 actually specifies.
///
/// Three properties this file is responsible for:
///
/// - **Confidentiality from the Relay.** Noise IK with the machine's static key
///   known in advance, so the party switching the bytes cannot read or alter
///   them, and cannot substitute itself.
/// - **A fresh start after every reconnect.** Neither dsh nor the Bridle resumes
///   a stream. A dropped connection ends every stream on it, the opener reopens
///   what it needs, and dsh answers each with a fresh baseline — a conversation
///   snapshot, the workspace list, the approvals still pending — which is how
///   dsh's own browser client recovers too (docs/dsh-0.2-migration.md D4).
/// - **Never hanging.** A phone changes network without telling anyone. Every
///   in-flight call has a deadline, every dropped socket fails its calls, and the
///   reconnect loop backs off rather than hammering.

import Foundation

/// What the app shows about a connection.
public enum TunnelStatus: Equatable, Sendable {
    /// Not started, or stopped on purpose.
    case idle
    /// Dialling, including every retry after the first.
    case connecting
    /// Live. `carrier` is how it got there and `harnessUp` is whether dsh answers.
    case online(carrier: Carrier, machine: String, harnessUp: Bool)
    /// Waiting to retry after a failure. `detail` is what went wrong last time.
    case waiting(detail: String, retryIn: TimeInterval, diagnosis: DialDiagnosis?)
    /// The machine will not accept this device. No amount of retrying fixes it.
    case refused(reason: RefusalReason)

    /// Connected or still trying — as opposed to stopped, or refused.
    public var isLive: Bool {
        switch self {
        case .connecting, .online, .waiting: return true
        case .idle, .refused: return false
        }
    }
}

/// Which path a live tunnel took.
public enum Carrier: String, Equatable, Sendable, Codable {
    /// A direct connection over the local network. No third party involved at all.
    case lan
    /// Through the Relay, which forwards ciphertext it cannot read.
    case relay
}

/// Why a machine refused a device. Each one needs different words on screen.
public enum RefusalReason: Equatable, Sendable {
    /// This device was never paired, or was revoked.
    case unpaired
    /// The app and the Bridle share no protocol version.
    ///
    /// Carries which end is behind, because "update the older one" is only
    /// actionable if we say which one that is. The machine tells us what it
    /// supports precisely so this can be answered.
    case version(appIsOlder: Bool)
    /// The machine failed internally during the handshake.
    case machineError(String)
}

/// What the machine said instead of opening a tunnel. `Tunnel.run` switches
/// over it, so a new kind of answer has to be handled rather than falling into
/// the retry-forever path meant for network failures.
enum HandshakeAnswer: Error {
    /// Final for this bundle; see `RefusalReason`.
    case refused(RefusalReason)
    /// The short-code token earned a request, and the person at the Mac has not
    /// accepted it yet (`bridle pair --code`). Not final: retried until they do.
    case pending
}

/// What one path did in one dial round, with its structure intact.
///
/// The dial used to flatten every failure into a joined string, and the one
/// structured fact the app ever receives about an unreachable machine — the
/// relay's close code, where 4404 means "that machine is offline", meaning
/// the Bridle is not registered — was destroyed on the way to the screen.
/// The offline screen then had nothing to reason from but its own prose.
public struct PathOutcome: Equatable, Sendable {
    /// Which kind of path failed — a Wi-Fi address or the relay.
    public let carrier: Carrier
    public let label: String
    /// The refusal close code, when the far end sent one. `nil` means the
    /// path failed below that level: timeout, no route, connection refused.
    public let closeCode: Int?
    public let reason: String
}

/// Everything the paths reported in the round of dialling that just failed.
///
/// Lives only inside the `waiting` status it describes: the next dial makes a
/// new one and a tunnel that comes up discards it — old evidence does not get
/// to testify about a new outage.
public struct DialDiagnosis: Equatable, Sendable {
    public let outcomes: [PathOutcome]

    /// The relay itself answered and said the machine is not registered.
    /// This is the one verdict strong enough to narrow the offline screen:
    /// the relay is reachable, so the network is fine, and the machine's
    /// Bridle is not connected to it.
    public var relaySaysOffline: Bool {
        outcomes.contains { $0.carrier == .relay && $0.closeCode == 4404 }
    }
}

/// Everything the tunnel tells the app about.
public enum TunnelSignal: Sendable {
    case status(TunnelStatus)
    /// The machine's harness went away or came back.
    case harness(reachable: Bool, detail: String?)
    /// A fresh handshake completed: every stream from before it is gone, and
    /// whoever needs one opens it again. `direct` is where the machine says it
    /// can be dialled locally right now.
    case handshake(ReadyFrame)
    /// One line about what the connection is doing, for the diagnostics screen.
    case note(ConnectionNote)
}

/// One dsh stream through the tunnel.
///
/// `items` ends when dsh ends the stream and throws when it fails; see
/// `Tunnel.open`. Iterate it from one task. `cancel` stops the stream at dsh —
/// as does cancelling the task that iterates it.
public struct TunnelStream: Sendable {
    public let sid: String
    public let items: AsyncThrowingStream<JSONValue, Error>
    public let cancel: @Sendable () -> Void
}

/// One line in the connection log.
///
/// This exists because of a bug that took forty minutes to find and would have
/// taken ten seconds to read: the app had shipped pointing at a relay hostname
/// that had moved, and every screen it could show said "Reaching…". There was
/// no way, from the phone, to learn which address it was dialling or what came
/// back — and the phone is the only place the failing network exists. A Mac
/// cannot reproduce a carrier's route to Cloudflare.
///
/// **Never contains a key, a token, a path, or anything from a conversation.**
/// Host and port, a verdict, and a duration. That bound is what lets this be
/// always-on and screenshot-safe rather than a debug mode someone has to have
/// enabled *before* the thing they need to diagnose.
public struct ConnectionNote: Identifiable, Sendable, Equatable {
    public enum Level: Sendable, Equatable {
        /// Starting something.
        case attempt
        /// It worked.
        case ok
        /// It did not.
        case fail
    }

    public let id: Int
    public let at: Date
    public let level: Level
    public let text: String
}

/// Every deadline the tunnel keeps, in one place.
///
/// Gathered into a value rather than left as file constants so a test can run
/// them in milliseconds. The failures worth testing here are all defined by
/// time — a carrier that has been quiet *too long*, an address that died *too
/// soon* after being adopted — and a suite that has to wait forty real seconds
/// to ask about the first one is a suite nobody runs.
///
/// The defaults are the shipping values, and each is explained where it is used.
public struct TunnelTimings: Sendable {
    /// How long a single harness call may take before the app gives up on it.
    public var call: TimeInterval = 120
    /// How long to wait for a carrier to answer the handshake.
    public var handshake: TimeInterval = 8

    /// Backoff ceiling. Past this the phone is probably not on a network at
    /// all, and `poke()` from the foreground observer will get there faster
    /// than any timer.
    public var maximumBackoff: TimeInterval = 30

    /// How often to ask again while the Mac decides whether to accept this
    /// device. Short, because a person is standing at the Mac waiting too.
    public var approvalPoll: TimeInterval = 3

    /// How long the Relay waits before joining a dial the local address started.
    ///
    /// RFC 8305's Connection Attempt Delay, and the value is the spec's rather
    /// than one of mine: 250ms, chosen there by measurement across production
    /// devices rather than by argument. curl settled on 200ms after its own,
    /// which is close enough to suggest the number is real. This was 400ms
    /// because 400 sounded careful.
    ///
    /// Long enough that a local handshake — tens of milliseconds on the same
    /// network — finishes first every time, so a phone at home never touches
    /// the Relay. The cost of being wrong is small and now smaller: a local
    /// address is only dialled when it is on a subnet this device holds, so
    /// off that network the Relay starts immediately and pays nothing at all.
    public var relayHeadStart: TimeInterval = 0.25

    /// How long the app will sit on a silent carrier before deciding it is dead.
    ///
    /// The Bridle pings every 25 seconds whether or not anything is happening,
    /// so silence longer than that is not a quiet conversation — it is a socket
    /// nobody has been told about. That is the ordinary end of a cellular
    /// connection: the radio hands over, the old flow is never delivered again,
    /// and nothing anywhere reports an error.
    ///
    /// Left alone this costs minutes. `URLSessionWebSocketTask.receive()` waits
    /// on dead TCP until the stack gives up, and for the whole of that wait the
    /// app says it is connected, shows a conversation that has moved on without
    /// it, and answers every tap with a call timeout. That is the failure this
    /// file's own header promises not to have.
    ///
    /// Reconnecting costs nothing to be wrong about: the handshake is fast and
    /// every stream reopens with a fresh baseline, so a false positive is a
    /// blink and a missed detection is minutes of lying.
    public var silenceLimit: TimeInterval = 40

    /// How often to check for that silence.
    public var livenessCheck: TimeInterval = 5

    /// How long a probed carrier gets to say anything at all.
    ///
    /// Generous against a slow relay round trip, and still an order of
    /// magnitude better than the silence limit it short-circuits: the probe
    /// runs when the app comes back to the foreground, which is exactly when
    /// someone is looking at the screen and about to tap something.
    public var probe: TimeInterval = 4

    /// A direct connection that dies this soon after being adopted was not
    /// worth adopting. Long enough to cover a handshake that succeeds onto
    /// Wi-Fi the phone is about to fall off, short enough that an ordinary
    /// evening's disconnection is not mistaken for one.
    public var flapWindow: TimeInterval = 20

    /// How long to leave a flapping address alone. Long enough that walking out
    /// of range does not produce a switch every time the signal returns; short
    /// enough that a router which was rebooting is forgiven within the sitting.
    public var flapPenalty: TimeInterval = 300

    public init() {}
}

public actor Tunnel {
    private let bundle: PairingBundle
    private let identity: StaticKeyPair
    private let clientVersion: String
    private let open: CarrierOpener
    private let onOurNetwork: @Sendable (URL) -> Bool
    private let timings: TunnelTimings
    private let watchNetwork: Bool
    private var deviceName: String
    private var pairingToken: String?

    private var carrier: (any Carrying)?
    private var channel: SecureChannel?
    private var loop: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?
    private var sendChain: Task<Void, Never> = Task {}
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    /// Open streams, by the id this end gave them.
    private var streams: [String: AsyncThrowingStream<JSONValue, Error>.Continuation] = [:]
    private var counter = 0
    private var noteCounter = 0
    /// When the last frame of any kind arrived, including the Bridle's pings.
    private var lastFrameAt = Date()
    private var watchdog: Task<Void, Never>?
    private var watcher: PathWatcher?
    /// The outstanding foreground probe, so a second poke does not stack one.
    private var probing: Task<Void, Never>?
    /// When the live carrier went direct, so a drop can be judged as flapping.
    private var lanAdoptedAt: Date?
    /// Do not dial a local address before this moment.
    private var lanBlockedUntil: Date?
    /// The machine's current LAN addresses, as told by the last `ready` frame.
    ///
    /// The bundle's copy is a snapshot from pairing day; this one is from the
    /// last time the machine actually answered. A Mac that moved to a hotspot
    /// is dialled where it is, not where it was. `nil` until a ready frame says
    /// — including from an old Bridle that never will, which keeps the bundle
    /// copy in use rather than discarding addresses that may still be right.
    private var learnedDirect: [String]?
    /// The APNs token to hand the machine, or nil once one has been withdrawn.
    private var wakeToken: String?
    /// Whether iOS has answered at all yet. See `sendWakeToken`.
    private var wakeTokenKnown = false

    private var continuation: AsyncStream<TunnelSignal>.Continuation?
    /// Structured evidence from the most recent failed dial round; see
    /// `DialDiagnosis` for its lifetime rule.
    private var lastDial: DialDiagnosis?

    private(set) public var status: TunnelStatus = .idle {
        didSet { if status != oldValue { continuation?.yield(.status(status)) } }
    }

    /// - Parameters:
    ///   - bundle: the pairing bundle for this machine.
    ///   - identity: this device's long-term key pair.
    ///   - deviceName: what the machine should call this device.
    ///   - clientVersion: app build string, shown in `bridle status`.
    ///   - pairingToken: present only until the first successful handshake.
    ///   - open: how to obtain a carrier. Tests pass a pair of in-memory pipes
    ///     so that a socket can be made to go quiet, or to be retired mid-read,
    ///     on demand — the two failures that made this file worth testing and
    ///     that a real WebSocket cannot be asked to perform.
    ///   - watchNetwork: whether to observe the system's network path. Off in
    ///     tests, where a real `NWPathMonitor` would fire on the machine running
    ///     them and start upgrades nobody asked for.
    public init(
        bundle: PairingBundle,
        identity: StaticKeyPair,
        deviceName: String,
        clientVersion: String,
        pairingToken: String?,
        open: @escaping CarrierOpener = { WebSocketCarrier.open(url: $0, timeout: $1) },
        onOurNetwork: @escaping @Sendable (URL) -> Bool = { isOnOurNetwork($0) },
        watchNetwork: Bool = true,
        timings: TunnelTimings = TunnelTimings()
    ) {
        self.bundle = bundle
        self.identity = identity
        self.deviceName = deviceName
        self.clientVersion = clientVersion
        self.pairingToken = pairingToken
        self.open = open
        self.onOurNetwork = onOurNetwork
        self.watchNetwork = watchNetwork
        self.timings = timings
    }

    /// The signal stream. One consumer at a time: a second call ends the first
    /// stream and takes over, and `stop()` ends it.
    public func signals() -> AsyncStream<TunnelSignal> {
        continuation?.finish()
        return AsyncStream { continuation in
            self.continuation = continuation
            continuation.yield(.status(status))
        }
    }

    /// Rename this device on the machine's paired list. Takes effect next connect.
    public func rename(to name: String) {
        deviceName = name
    }

    /// Add one line to the connection log.
    private func note(_ level: ConnectionNote.Level, _ text: String) {
        noteCounter += 1
        continuation?.yield(.note(ConnectionNote(id: noteCounter, at: Date(), level: level, text: text)))
    }

    /// Start connecting, and keep reconnecting until `stop()`.
    public func start() {
        guard loop == nil else { return }
        if watchNetwork {
            watcher = PathWatcher { [weak self] onWiFi in
                Task { await self?.networkChanged(onWiFi: onWiFi) }
            }
        }
        loop = Task { await self.run() }
    }

    /// Stop, fail everything in flight, and release the socket.
    public func stop() {
        loop?.cancel()
        loop = nil
        sleeper?.cancel()
        watcher = nil
        teardown(reason: "closed by the app")
        status = .idle
        continuation?.finish()
        continuation = nil
    }

    /// Retry now instead of waiting out the backoff. Called when the app comes
    /// to the foreground or the network path changes.
    ///
    /// Also the moment to distrust a connection that looks fine. Coming back to
    /// the app is exactly when the socket is most likely to have died unheard —
    /// iOS suspended the process, the radio moved on without it — so this
    /// checks rather than waiting out the watchdog's next tick.
    public func poke() {
        sleeper?.cancel()
        checkLiveness()
        probeCarrier()
        // Coming back is also the likeliest moment to have walked in the door
        // while the app was asleep, still holding a relayed connection.
        considerUpgrade()
    }

    /// Force a verdict out of a carrier that merely looks connected.
    ///
    /// The watchdog answers "has anything arrived lately", and after a short
    /// suspension the honest answer is yes — twenty seconds ago, before iOS
    /// froze the process and quietly killed the socket. Waiting out the rest
    /// of the silence limit is what made every reopen of the app cost half a
    /// minute of dead taps: the directory listing, the new conversation, the
    /// send, all queued on a socket that would never answer.
    ///
    /// So ask. A ping forces the Bridle to say something; if nothing at all
    /// arrives within {@link TunnelTimings.probe} of asking, the carrier is
    /// closed and the reconnect loop — which takes a second or two — does the
    /// rest. Any frame counts as the answer, not just the pong: proof of life
    /// is proof of life.
    private func probeCarrier() {
        guard carrier != nil, probing == nil else { return }
        let asked = Date()
        note(.attempt, "Checking the connection is still alive")
        try? write(PingFrame(nonce: "probe-\(Int(asked.timeIntervalSince1970))"))
        let wait = timings.probe
        probing = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.settleProbe(askedAt: asked)
        }
    }

    private func settleProbe(askedAt: Date) {
        probing = nil
        guard let socket = carrier else { return }
        guard lastFrameAt < askedAt else { return }
        note(.fail, "No answer to the probe in \(elapsed(Date().timeIntervalSince(askedAt))) — reconnecting")
        socket.close("did not answer a probe")
    }

    // MARK: - Calls

    /// Invoke one dsh endpoint.
    ///
    /// - Parameters:
    ///   - endpoint: `<namespace>/<method>`, e.g. `session/list`.
    ///   - args: the endpoint's arguments, with exactly the names dsh declares.
    /// - Throws: `CallError`. `disconnected` means nothing was sent and the call
    ///   may be retried; `interrupted` and `timeout` mean it was sent and its
    ///   outcome is unknown (`CallError.outcomeUnknown`); anything else came
    ///   from dsh or the Bridle.
    @discardableResult
    public func call(_ endpoint: String, _ args: JSONValue = .emptyObject) async throws -> JSONValue {
        counter += 1
        let id = "c\(counter)"
        let frame = CallFrame(id: id, endpoint: endpoint, args: args)
        return try await withRequest(id: id) { try self.write(frame) }
    }

    /// Open a dsh stream.
    ///
    /// Items arrive in order. The sequence ends when dsh ends the stream, and
    /// throws a `CallError` when it fails — `disconnected` when this tunnel
    /// drops, `upstream-lost` when the Bridle's connection to dsh does; either
    /// way the opener opens it again and gets a fresh baseline. Cancelling the
    /// consuming task, or `TunnelStream.cancel()`, stops it at dsh.
    public func open(_ endpoint: String, _ args: JSONValue = .emptyObject) -> TunnelStream {
        counter += 1
        let sid = "s\(counter)"
        var continuation: AsyncThrowingStream<JSONValue, Error>.Continuation!
        let items = AsyncThrowingStream<JSONValue, Error>(bufferingPolicy: .unbounded) { continuation = $0 }
        guard case .online = status else {
            continuation.finish(throwing: CallError(code: "disconnected", message: "Not connected to that Mac."))
            return TunnelStream(sid: sid, items: items, cancel: {})
        }
        streams[sid] = continuation
        continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            Task { await self?.cancelStream(sid) }
        }
        do {
            try write(OpenFrame(sid: sid, endpoint: endpoint, args: args))
        } catch {
            streams.removeValue(forKey: sid)
            continuation.finish(throwing: CallError(code: "disconnected", message: "Not connected to that Mac."))
        }
        return TunnelStream(sid: sid, items: items, cancel: { [weak self] in
            Task { await self?.cancelStream(sid) }
        })
    }

    /// Stop a stream at dsh; nothing more is delivered for it.
    private func cancelStream(_ sid: String) {
        guard let continuation = streams.removeValue(forKey: sid) else { return }
        continuation.finish()
        try? write(CancelFrame(sid: sid))
    }

    /// Offer, or withdraw, somewhere to be woken when this app is not running.
    ///
    /// Held rather than sent-and-forgotten: the tunnel it would go down does
    /// not exist yet at the moment iOS hands over a token, and will be replaced
    /// several times a day afterwards. The machine is told on every `ready`.
    /// - Parameters:
    ///   - token: the APNs device token as lowercase hex, or nil to stop being
    ///     woken — which is what turning notifications off looks like.
    public func offerWake(token: String?) {
        guard !wakeTokenKnown || token != wakeToken else { return }
        wakeToken = token
        wakeTokenKnown = true
        sendWakeToken()
    }

    private func sendWakeToken() {
        guard case .online = status else { return }
        // Nothing to say yet is different from having withdrawn: before iOS
        // answers, a nil would tell the machine to forget a token it already
        // has and stop ringing a phone that still wants to be rung.
        guard wakeTokenKnown else { return }
        try? write(WakeFrame(token: wakeToken))
    }

    private func withRequest(id: String, _ send: @escaping () throws -> Void) async throws -> JSONValue {
        let limit = timings.call
        let deadline = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.settle(id, .failure(CallError(code: "timeout", message: "The Mac did not answer in time.")))
        }
        defer { deadline.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try send()
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    private func settle(_ id: String, _ result: Result<JSONValue, Error>) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    /// Encrypt one frame and hand it to the send queue.
    ///
    /// The cipher counter advances at encryption time, so frames have to reach
    /// the wire in the order they were encrypted — a frame that overtakes its
    /// predecessor fails to authenticate and tears the tunnel down. Encryption
    /// is synchronous on the actor, which fixes the order; `sendChain` then keeps
    /// the awaits in that same order instead of letting the runtime interleave
    /// them.
    private func write(_ frame: TunnelFrame) throws {
        guard let channel, let carrier else {
            throw CallError(code: "disconnected", message: "Not connected to that Mac.")
        }
        let bytes = try channel.encrypt(try frame.encoded())
        let previous = sendChain
        sendChain = Task {
            await previous.value
            try? await carrier.send(bytes)
        }
    }

    // MARK: - Connection loop

    private func run() async {
        var backoff: TimeInterval = 0.5
        while !Task.isCancelled {
            status = .connecting
            do {
                try await connectOnce()
                backoff = 0.5
                try await pump()
            } catch let answer as HandshakeAnswer {
                switch answer {
                case .pending:
                    teardown(reason: "awaiting approval")
                    if Task.isCancelled { return }
                    let detail = "Accept this iPhone on your Mac. It shows the key \(Pairing.keyFingerprint(identity.publicKey)) — check the Mac shows the same."
                    note(.fail, "Waiting for the Mac to accept this iPhone")
                    status = .waiting(detail: detail, retryIn: timings.approvalPoll, diagnosis: nil)
                    await sleep(timings.approvalPoll)
                    continue
                case .refused(let refusal):
                    note(.fail, "Refused by the Mac")
                    status = .refused(reason: refusal)
                    teardown(reason: "refused")
                    // Final for this bundle, but not for this tunnel: `start()`
                    // must be able to run it again, and it refuses while a loop
                    // is held.
                    loop = nil
                    return
                }
            } catch {
                teardown(reason: "\(error.localizedDescription)")
                if Task.isCancelled { return }
                let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                note(.fail, "\(detail) Retrying in \(elapsed(backoff))")
                status = .waiting(detail: detail, retryIn: backoff, diagnosis: lastDial)
                await sleep(backoff)
                backoff = min(backoff * 2, timings.maximumBackoff)
                continue
            }
            // `pump` returned without throwing only if it was cancelled.
            return
        }
    }

    /// Dial every way of reaching the machine at once and adopt the first that
    /// answers.
    ///
    /// This used to try the LAN addresses and then the Relay, one after the
    /// other, and that ordering was a bug wearing the clothes of an
    /// optimisation. A LAN address is unroutable from a phone on cellular, and
    /// an unroutable address does not fail — it times out. Two of them cost
    /// sixteen seconds before the Relay was dialled at all, on the one network
    /// where the Relay is the only path that can work.
    ///
    /// So they race. The Relay starts {@link relayHeadStart} late, which is the
    /// whole of the old preference expressed as a number: on Wi-Fi the local
    /// round trip finishes in tens of milliseconds and wins outright, so the
    /// Relay is not dialled at all and never learns the session happened. Off
    /// Wi-Fi the head start is the entire cost of trying, and the LAN attempts
    /// simply time out unheard alongside a connection that is already up.
    ///
    /// A pairing token is one-time, and racing cannot waste it: the Bridle
    /// records this device's static key the moment it accepts a handshake, so
    /// any later attempt from the same device is recognised without a token.
    private func connectOnce() async throws {
        let plan = candidates()
        guard let remoteStatic = bundle.staticKey else {
            throw HandshakeAnswer.refused(.machineError("That pairing code has no machine key."))
        }
        guard !plan.isEmpty else {
            throw CarrierError(reason: "No way to reach that Mac.", closeCode: nil)
        }
        let (winner, failures, refusal) = await dial(plan, remoteStatic: remoteStatic)
        // `stop()` may have landed while the dial was out. Adopting what came
        // back would put a stopped tunnel back online, with a socket that keeps
        // the Mac believing someone is listening — which silences its pushes.
        // The window is narrow (a racer that won just before the cancel), too
        // narrow to provoke in the test harness, where a cancelled dial simply
        // loses; this check is what closes it.
        if Task.isCancelled {
            winner?.socket.close("stopped")
            throw CancellationError()
        }

        // A refusal outranks a win. It means the machine has an opinion about
        // this device — unpaired, or a protocol it cannot speak — and adopting
        // some other carrier's success would hide an answer that no amount of
        // retrying changes.
        if let refusal {
            winner?.socket.close("refused")
            throw refusal
        }
        guard let winner else {
            if Task.isCancelled { throw CancellationError() }
            throw CarrierError(reason: dialFailure(failures), closeCode: nil)
        }

        note(.ok, "Connected over \(winner.label) in \(elapsed(winner.took))")
        // A tunnel that came up ends the previous outage; its evidence is spent.
        lastDial = nil
        adopt(winner)
    }

    /// Race a set of candidates and return the first handshake that completed.
    ///
    /// Shared by the opening dial and by the upgrade to Wi-Fi, which are the
    /// same operation asked at different moments — and which must stay the same
    /// operation, because the second one exists to hand over to a connection
    /// indistinguishable from one the first would have made.
    private func dial(
        _ plan: [Candidate],
        remoteStatic: Data
    ) async -> (winner: Attempt?, failures: [String], refusal: HandshakeAnswer?) {
        let request = HandshakeRequest(name: deviceName, client: clientVersion, token: pairingToken)
        for candidate in plan { note(.attempt, "Dialling \(candidate.label)") }

        var winner: Attempt?
        var failures: [String] = []
        var outcomes: [PathOutcome] = []
        var refusal: HandshakeAnswer?

        await withTaskGroup(of: Outcome.self) { group in
            for candidate in plan {
                group.addTask {
                    await Tunnel.race(candidate, identity: self.identity, remoteStatic: remoteStatic, request: request, open: self.open, timeout: self.timings.handshake)
                }
            }
            for await outcome in group {
                switch outcome {
                case .won(let attempt):
                    // A second winner is possible: cancellation is cooperative
                    // and a racer already past its last checkpoint runs to
                    // completion. Closing the loser here is what stops the
                    // Bridle holding a socket nobody reads.
                    if winner == nil {
                        winner = attempt
                        group.cancelAll()
                    } else {
                        attempt.socket.close("lost the race")
                    }
                case .failed(let label, let carrier, let code, let reason, let took):
                    failures.append("\(label): \(reason)")
                    outcomes.append(PathOutcome(carrier: carrier, label: label, closeCode: code, reason: reason))
                    note(.fail, "\(label) failed after \(elapsed(took)) — \(reason)")
                case .refused(let reason):
                    refusal = reason
                    group.cancelAll()
                case .cancelled:
                    break
                }
            }
        }
        lastDial = outcomes.isEmpty ? nil : DialDiagnosis(outcomes: outcomes)
        return (winner, failures, refusal)
    }

    /// Turn what each path did wrong into one sentence a person can act on.
    ///
    /// Every path, not just the last one. "Could not reach that address" is a
    /// different problem depending on whether it came from the Wi-Fi attempt or
    /// the Relay, and the old code kept only whichever failed last.
    private func dialFailure(_ failures: [String]) -> String {
        guard !failures.isEmpty else { return "Could not reach that Mac." }
        return failures.joined(separator: " · ") + "."
    }

    /// Watch for a carrier that has stopped delivering.
    ///
    /// Deliberately not a timeout on `receive()`: a tunnel is idle most of the
    /// time and an idle tunnel is healthy. What distinguishes the two is the
    /// Bridle's ping, which arrives whether or not anyone is talking, so the
    /// question worth asking is "when did anything last arrive", not "how long
    /// has this read been waiting".
    private func startWatchdog() {
        watchdog?.cancel()
        let interval = timings.livenessCheck
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.checkLiveness()
            }
        }
    }

    /// Drop a carrier that has gone quiet for longer than the Bridle's ping.
    private func checkLiveness() {
        guard let socket = carrier else { return }
        let silence = Date().timeIntervalSince(lastFrameAt)
        guard silence > timings.silenceLimit else { return }
        note(.fail, "Nothing heard for \(elapsed(silence)) — treating the connection as dead")
        // Closing is the whole action. It makes the blocked `receive()` throw,
        // which throws out of `pump`, which the reconnect loop already knows
        // how to handle — including failing the calls that were waiting on a
        // socket that was never going to answer.
        socket.close("silent for \(Int(silence))s")
    }

    // MARK: - Upgrading to the local network

    /// Move a relayed connection onto the local network by reconnecting.
    ///
    /// A phone that walks in the door goes on talking through Cloudflare,
    /// because the relay is working and nothing asks it to stop: an extra
    /// round trip on every keystroke, a request budget spent on traffic that
    /// never needed to leave the flat, and a third party told a session is
    /// happening between two machines a metre apart.
    ///
    /// The first version of this built a second tunnel, swapped it in, and
    /// retired the old one — seamless, and about a hundred and fifty lines,
    /// including a generation counter that the receive loop had to consult on
    /// every frame to know whether the bytes in its hand belonged to a socket
    /// already thrown away. All of it bought one property: no visible blink.
    ///
    /// That property is not worth it. Reconnecting is the best-tested path in
    /// this file — a phone does it every time the radio sleeps — and nothing is
    /// lost by it: every stream reopens with a fresh baseline from dsh.
    /// It costs about a second and a line of grey text. So the upgrade is now
    /// the same thing a dropped connection is, deliberately: close the socket
    /// and let the reconnect happen. The opening race already prefers the
    /// local address, because the relay starts {@link TunnelTimings.relayHeadStart}
    /// late, so "try Wi-Fi again" needs no machinery of its own — it is just
    /// "dial again, from here".
    ///
    /// What is left is the part that is actually load-bearing: *when* to do it
    /// (on a change, never on a timer), and *not while a call is outstanding*,
    /// since a reply has nowhere to be replayed from.
    private func considerUpgrade() {
        guard case .online(.relay, _, _) = status else { return }
        guard pending.isEmpty else { return }
        guard !candidates().filter({ $0.carrier == .lan }).isEmpty else { return }
        note(.attempt, "Wi-Fi is available — reconnecting to try the local address")
        carrier?.close("looking for a local address")
    }

    /// Record that a direct connection did not last, so the next dial does not
    /// walk straight back into it.
    ///
    /// Per path rather than per address. The distinction bought nothing: the
    /// addresses on offer are one real interface and a Docker bridge that never
    /// answers, and "the local path is unreliable right now" is the whole of
    /// what the app can usefully know. One date instead of a dictionary.
    private func penaliseIfItFlapped() {
        guard let at = lanAdoptedAt else { return }
        lanAdoptedAt = nil
        let lasted = Date().timeIntervalSince(at)
        guard lasted < timings.flapWindow else { return }
        lanBlockedUntil = Date().addingTimeInterval(timings.flapPenalty)
        note(.fail, "The local address dropped after \(elapsed(lasted)) — leaving it alone for a while")
    }

    /// The phone's network changed under the connection.
    private func networkChanged(onWiFi: Bool) {
        note(.attempt, onWiFi ? "Joined a Wi-Fi network" : "Left Wi-Fi")
        // Retry now rather than sitting out a backoff that was set for a
        // network that no longer exists.
        sleeper?.cancel()
        // The subnets just changed, so what counts as reachable changed with
        // them; asking again is the whole response.
        considerUpgrade()
        if !onWiFi, case .online(.lan, _, _) = status {
            // A local address is not merely slow without Wi-Fi, it is
            // unreachable, so there is nothing to wait forty seconds to learn.
            note(.fail, "Wi-Fi went away while connected directly — reconnecting")
            carrier?.close("left the network")
        }
    }

    /// Move a finished handshake into place as the live tunnel.
    private func adopt(_ attempt: Attempt) {
        carrier = attempt.socket
        channel = attempt.channel
        lastFrameAt = Date()
        startWatchdog()
        pairingToken = nil
        status = .online(
            carrier: attempt.carrier,
            machine: attempt.reply.machine ?? bundle.name,
            harnessUp: false
        )
        lanAdoptedAt = attempt.carrier == .lan ? Date() : nil
    }

    /// One address worth trying.
    private struct Candidate: Sendable {
        let url: URL
        let carrier: Carrier
        /// What to call it on screen and in the log. Host and port only — never
        /// a key, a token, or anything from a conversation.
        let label: String
        /// How long to wait before starting, so a preference can be expressed
        /// without giving up the parallelism.
        let delay: TimeInterval
    }

    /// A handshake that completed, before anyone has adopted it.
    private struct Attempt: @unchecked Sendable {
        let socket: any Carrying
        let channel: SecureChannel
        let reply: HandshakeReply
        let carrier: Carrier
        let label: String
        let took: TimeInterval
    }

    private enum Outcome: @unchecked Sendable {
        case won(Attempt)
        case failed(label: String, carrier: Carrier, code: Int?, reason: String, took: TimeInterval)
        /// The machine answered, and not with a tunnel.
        case refused(HandshakeAnswer)
        case cancelled
    }

    private func candidates() -> [Candidate] {
        var found: [Candidate] = []
        // A penalised path is skipped by the opening dial too, not just by the
        // upgrade. Racing an address that has just proved it drops connections
        // is how a flap becomes a loop: it wins precisely because it is local,
        // then dies, then wins again.
        let blocked = lanBlockedUntil.map { Date() < $0 } ?? false
        for address in blocked ? [] : (learnedDirect ?? bundle.direct ?? []) {
            guard let url = URL(string: "\(address)/v1/tunnel") else { continue }
            // Only addresses on a network this device is actually on. Off that
            // network the dial cannot succeed, and its only effect is to make
            // the relay wait out a head start for a race with one runner.
            guard onOurNetwork(url) else { continue }
            found.append(Candidate(url: url, carrier: .lan, label: "Wi-Fi \(Tunnel.place(url))", delay: 0))
        }
        if var components = URLComponents(string: bundle.relay) {
            components.scheme = components.scheme == "https" || components.scheme == "wss" ? "wss" : "ws"
            components.path = "/v1/app"
            components.queryItems = [URLQueryItem(name: "device", value: bundle.device)]
            if let url = components.url {
                found.append(Candidate(
                    url: url,
                    carrier: .relay,
                    label: "Relay \(Tunnel.place(url))",
                    // No LAN address to lose to means nothing to wait for.
                    delay: found.isEmpty ? 0 : timings.relayHeadStart
                ))
            }
        }
        return found
    }

    /// Host and port, which is all of a URL that is safe to show and all of it
    /// that helps: the path is a constant and the query carries the device id.
    private nonisolated static func place(_ url: URL) -> String {
        let host = url.host ?? "?"
        guard let port = url.port else { return host }
        return "\(host):\(port)"
    }

    /// Run one candidate to a verdict, touching nothing shared.
    ///
    /// Deliberately not a method on the actor: a racer that hops onto the
    /// actor's executor to do its waiting is not racing, it is queueing, and
    /// the whole point here is that the attempts overlap.
    private nonisolated static func race(
        _ candidate: Candidate,
        identity: StaticKeyPair,
        remoteStatic: Data,
        request: HandshakeRequest,
        open: CarrierOpener,
        timeout: TimeInterval
    ) async -> Outcome {
        if candidate.delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(candidate.delay * 1_000_000_000))
            if Task.isCancelled { return .cancelled }
        }
        let started = Date()
        let socket = open(candidate.url, timeout)
        // Closing is the only thing that reliably stops an attempt, so it is
        // what both the deadline and the loss of the race do.
        //
        // Measured cost of not having this: a dial reported failure after 198
        // seconds with the relay already connected and idle the whole time. A
        // task group does not return until every child has, only `receive` was
        // under a deadline, and a `send` to an address that no longer exists
        // ignored cancellation. So the winner waited on the losers.
        //
        // `onCancel` covers the ordinary case — a winner cancels the group and
        // every loser drops immediately. The deadline covers the case with no
        // winner at all, and bounds the whole dial by the handshake timeout.
        return await withTaskCancellationHandler {
            await Tunnel.attempt(candidate, socket: socket, started: started, identity: identity,
                                 remoteStatic: remoteStatic, request: request, timeout: timeout)
        } onCancel: {
            socket.close("lost the race")
        }
    }

    /// The handshake itself, once a socket exists.
    private nonisolated static func attempt(
        _ candidate: Candidate,
        socket: any Carrying,
        started: Date,
        identity: StaticKeyPair,
        remoteStatic: Data,
        request: HandshakeRequest,
        timeout: TimeInterval
    ) async -> Outcome {
        // Bound the whole attempt, not just the read.
        //
        // Only `receive` used to be under a deadline, and the observed cost was
        // a dial that reported failure after 198 seconds — with the relay
        // already connected and waiting the whole time, because a task group
        // does not return until every child has. A `send` to an address that no
        // longer exists is where it hung, and cancellation could not reach it.
        //
        // Closing the socket can, and does it whatever the operation was: it
        // makes both `send` and `receive` fail at once. That keeps the drain
        // after a winner bounded by the handshake timeout rather than by
        // whatever URLSession decides to do with a black hole.
        let deadline = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if Task.isCancelled { return }
            socket.close("did not answer within \(Int(timeout))s")
        }
        defer { deadline.cancel() }
        do {
            let initiator = try NoiseInitiator(staticKeys: identity, remoteStatic: remoteStatic, prologue: tunnelPrologue)
            try await socket.send(initiator.writeMessage(try request.encoded()))
            let reply = try await withTimeout(timeout) { try await socket.receive() }
            let opened = try initiator.readMessage(reply)
            let answer = try JSONDecoder().decode(HandshakeReply.self, from: opened.payload)
            guard answer.ok else {
                socket.close("refused")
                switch answer.reason {
                case "unpaired": return .refused(.refused(.unpaired))
                case "pending": return .refused(.pending)
                case "version": return .refused(.refused(.version(appIsOlder: answer.weAreTheOldEnd)))
                default: return .refused(.refused(.machineError(answer.reason ?? "unknown")))
                }
            }
            if Task.isCancelled {
                socket.close("lost the race")
                return .cancelled
            }
            return .won(Attempt(
                socket: socket,
                channel: opened.channel,
                reply: answer,
                carrier: candidate.carrier,
                label: candidate.label,
                took: Date().timeIntervalSince(started)
            ))
        } catch {
            socket.close("handshake failed")
            if Task.isCancelled { return .cancelled }
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // The close code travels whole. Flattening it here is how the app
            // once lost the only structured fact it ever gets about an
            // unreachable machine.
            return .failed(label: candidate.label, carrier: candidate.carrier,
                           code: (error as? CarrierError)?.closeCode, reason: reason,
                           took: Date().timeIntervalSince(started))
        }
    }

    /// Read frames until the socket dies or the task is cancelled.
    ///
    private func pump() async throws {
        guard let socket = carrier, let channel else {
            throw CallError(code: "disconnected", message: "Not connected.")
        }
        while !Task.isCancelled {
            let bytes = try await socket.receive()
            lastFrameAt = Date()
            let plaintext: Data
            do {
                plaintext = try channel.decrypt(bytes)
            } catch {
                // A frame that fails authentication means this carrier is no
                // longer trustworthy for anything. Tearing down is the only safe
                // response; the reconnect gets a fresh handshake.
                throw CarrierError(reason: "The connection was tampered with and has been closed.", closeCode: nil)
            }
            handle(try ServerFrame.decode(plaintext))
        }
    }

    private func handle(_ frame: ServerFrame) {
        switch frame {
        case .ready(let ready):
            var learned = false
            if let direct = ready.direct, direct != learnedDirect {
                learnedDirect = direct
                note(.ok, direct.isEmpty
                    ? "The Mac says it has no direct address"
                    : "The Mac is now at \(direct.compactMap { URL(string: $0).map(Tunnel.place) }.joined(separator: ", "))")
                // Learning an address is itself a reason to try it. Without
                // this the two triggers — a path change and a return to the
                // foreground — both miss the case that actually happens: a Mac
                // that moved networks while the phone was away. The stored
                // address is stale, so the opening race loses it and the relay
                // wins; the ready frame then hands over the address that would
                // have won, and nothing asks again. Measured on a machine that
                // had moved to a different office network: relayed for as long
                // as the app stayed open, a metre from the Mac.
                learned = true
            }
            status = .online(carrier: currentCarrier, machine: ready.machine, harnessUp: ready.dshReachable)
            continuation?.yield(.handshake(ready))
            continuation?.yield(.harness(reachable: ready.dshReachable, detail: ready.detail))
            // Re-offered on every ready rather than once, because the machine
            // is what stores it and a machine can be reinstalled, restored from
            // a backup, or simply be a different one. Sending it again costs a
            // frame that the Bridle drops when nothing changed.
            sendWakeToken()
            // After the status is settled, so the guard inside sees the live
            // carrier rather than the one being replaced.
            if learned { considerUpgrade() }
        case .result(let id, let result):
            settle(id, result.mapError { $0 as Error })
        case .item(let sid, let value):
            streams[sid]?.yield(value)
        case .end(let sid):
            streams.removeValue(forKey: sid)?.finish()
        case .error(let sid, let error):
            streams.removeValue(forKey: sid)?.finish(throwing: error)
        case .status(let reachable, let detail):
            if case .online(let carrier, let machine, _) = status {
                status = .online(carrier: carrier, machine: machine, harnessUp: reachable)
            }
            continuation?.yield(.harness(reachable: reachable, detail: detail))
        case .ping(let nonce):
            try? write(PongFrame(nonce: nonce))
        case .pong:
            break
        case .fault(let code, let message):
            // The Bridle does not send this today. Should one arrive, closing is
            // the honest answer: the reconnect loop owns what the status says,
            // and setting `.refused` here was overwritten by `.waiting` a moment
            // later anyway. A real refusal comes in the handshake.
            note(.fail, "The Mac reported a fault: \(code) — \(message)")
            carrier?.close("fault: \(code)")
        case .unknown:
            // Frames a newer Bridle sends. Ignoring them is what lets the
            // protocol grow without stranding installed apps.
            break
        }
    }

    private var currentCarrier: Carrier {
        if case .online(let carrier, _, _) = status { return carrier }
        return .relay
    }

    private func teardown(reason: String) {
        watchdog?.cancel()
        watchdog = nil
        probing?.cancel()
        probing = nil
        penaliseIfItFlapped()
        carrier?.close(reason)
        carrier = nil
        channel = nil
        let waiting = pending
        pending.removeAll()
        for (_, continuation) in waiting {
            // Not "disconnected": these calls were written, and may have taken
            // effect. See `CallError.outcomeUnknown`.
            continuation.resume(throwing: CallError(code: "interrupted", message: "The connection to that Mac dropped before it answered."))
        }
        // Streams have no outcome to be unsure of: they are simply over, and
        // their openers reopen them on the next connection.
        let open = streams
        streams.removeAll()
        for (_, continuation) in open {
            continuation.finish(throwing: CallError(code: "disconnected", message: "The connection to that Mac dropped."))
        }
    }

    private func sleep(_ seconds: TimeInterval) async {
        let task = Task {
            _ = try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        sleeper = task
        await task.value
        sleeper = nil
    }
}

/// A duration, short enough to read at a glance in a log line.
private func elapsed(_ seconds: TimeInterval) -> String {
    seconds < 1 ? "\(Int((seconds * 1000).rounded()))ms" : String(format: "%.1fs", seconds)
}

/// Race an operation against a deadline.
private func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw CarrierError(reason: "The Mac did not answer in time.", closeCode: nil)
        }
        guard let first = try await group.next() else {
            throw CarrierError(reason: "The Mac did not answer.", closeCode: nil)
        }
        group.cancelAll()
        return first
    }
}

extension RefusalReason: Error, LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unpaired: return "This iPhone isn’t paired with that Mac any more."
        case .version: return "The Rowel app and that Mac’s Bridle are different versions."
        case .machineError(let detail): return detail
        }
    }
}

// MARK: - Test seam

extension Tunnel {
    /// Pretend the system reported a network change.
    ///
    /// The real signal comes from `NWPathMonitor`, which cannot be asked to
    /// produce one — and the behaviour worth testing is entirely what happens
    /// *after* the signal: whether the connection moves off the relay, and
    /// whether it declines to try when there is no Wi-Fi to move onto.
    func networkChangedForTesting(onWiFi: Bool) {
        networkChanged(onWiFi: onWiFi)
    }
}
