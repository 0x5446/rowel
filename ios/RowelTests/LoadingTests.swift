/// How a conversation gets loaded, and loaded again.
///
/// Since tunnel version 2 a conversation is a `session/follow` stream: a
/// snapshot, then every event. Nothing resumes — a reconnect, or dsh coming
/// back, opens everything again and the new snapshot replaces what was held.
/// Each case here is one part of that: which streams open when, what a failure
/// does to them, and what a replaced window must keep.

import Observation
import XCTest
@testable import Rowel

/// A machine whose answers the test scripts, and whose streams it plays.
private actor ScriptedTransport: HarnessTransport {
    nonisolated let desk = StreamDesk()
    private var answers: [String: [Result<JSONValue, CallError>]] = [:]
    private(set) var sent: [(endpoint: String, args: JSONValue)] = []

    /// Queue an answer.
    func answer(_ endpoint: String, _ value: JSONValue) {
        answers[endpoint, default: []].append(.success(value))
    }

    func fail(_ endpoint: String, code: String) {
        answers[endpoint, default: []].append(.failure(CallError(code: code, message: code)))
    }

    func count(_ endpoint: String) -> Int { sent.filter { $0.endpoint == endpoint }.count }

    func payloads(_ endpoint: String) -> [JSONValue] { sent.filter { $0.endpoint == endpoint }.map(\.args) }

    func call(_ endpoint: String, _ args: JSONValue) async throws -> JSONValue {
        sent.append((endpoint, args))
        guard var queue = answers[endpoint], !queue.isEmpty else {
            throw CallError(code: "not-found", message: "unscripted \(endpoint)")
        }
        let next = queue.removeFirst()
        answers[endpoint] = queue
        return try next.get()
    }

    nonisolated func open(_ endpoint: String, _ args: JSONValue) async -> TunnelStream {
        desk.open(endpoint, args)
    }
}

@MainActor
final class LoadingTests: XCTestCase {
    private var suite: UserDefaults!
    private let suiteName = "rowel.tests.loading"

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: suiteName)
        suite.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func machine(_ transport: ScriptedTransport) -> MachineSession {
        MachineSession(
            machine: PairedMachine(bundle: PairingBundle(relay: "https://relay.invalid", device: "d", key: "", token: "", name: "Mac")),
            identity: .generate(),
            deviceName: "iPhone",
            clientVersion: "rowel-tests/1",
            pairingToken: nil,
            notifier: Notifier(center: nil),
            defaults: suite,
            transport: transport
        )
    }

    /// A handshake from a Bridle whose dsh is up, with the session list it
    /// will be asked for.
    private func connect(_ session: MachineSession, _ transport: ScriptedTransport) async {
        await transport.answer("session/list", .object(["items": .array([])]))
        session.receiveForTesting(.handshake(.test()))
    }

    private func event(_ type: String, seq: Int, data: JSONValue) -> JSONValue {
        .object(["type": .string(type), "seq": .number(Double(seq)), "time": .number(1_700_000_000_000), "data": data])
    }

    private func said(_ text: String, seq: Int, requestId: String? = nil) -> JSONValue {
        event("user/message", seq: seq, data: .object([
            "id": .string("m\(seq)"),
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "source": .object(dropping: ["kind": .string("user"), "rpcId": requestId.map(JSONValue.string)]),
        ]))
    }

    private func toolCall(_ id: String, seq: Int) -> JSONValue {
        event("tool/call", seq: seq, data: .object(["callId": .string(id), "name": .string("bash"), "arguments": .string("{}")]))
    }

    private func toolResult(_ id: String, seq: Int) -> JSONValue {
        event("tool/result", seq: seq, data: .object(["message": .object([
            "source": .object(["kind": .string("tool"), "callId": .string(id)]),
            "toolCallId": .string(id),
            "content": .array([.object(["type": .string("text"), "text": .string("done")])]),
        ])]))
    }

    private func until(_ what: String, _ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out waiting for \(what)")
    }

    /// Asking for a conversation that is already open is a read. It used to
    /// record "most recently opened" in observable state, and `SessionInfoView`
    /// asked from its `body` — so rendering the sheet invalidated the sheet,
    /// forever: a 36 s freeze on a phone, main thread inside
    /// `SessionInfoView.body` → `conversation(_:)` → `recent.modify`.
    func testAskingForAnOpenConversationNotifiesNobody() {
        let session = machine(ScriptedTransport())
        _ = session.conversation("s1")
        var notified = false
        withObservationTracking {
            _ = session.conversation("s1")
        } onChange: {
            notified = true
        }
        _ = session.conversation("s1")
        XCTAssertFalse(notified, "re-asking for an open conversation must not invalidate whoever asked")
    }

    // MARK: - What opens when

    func testAHandshakeOpensTheMachineStreamsAndListsTheSessions() async throws {
        let transport = ScriptedTransport()
        let session = machine(transport)
        await connect(session, transport)

        try await until("the three machine streams") {
            transport.desk.count("$events") == 1
                && transport.desk.count("workspace/follow") == 1
                && transport.desk.count("session/control") == 1
        }
        try await until("the session list") { session.everListed }
        XCTAssertNil(session.problem)
    }

    func testOpeningAConversationFollowsIt() async throws {
        let transport = ScriptedTransport()
        let session = machine(transport)
        await connect(session, transport)
        let conversation = session.conversation("s1")
        XCTAssertTrue(conversation.loading, "until the snapshot lands this is loading, not empty")

        try await until("the follow") { transport.desk.count("session/follow") == 1 }
        let args = transport.desk.args("session/follow").first
        XCTAssertEqual(args?.path("request", "address", "sessionId")?.stringValue, "s1")
        XCTAssertEqual(args?.path("request", "assistantStream")?.boolValue, true)
        XCTAssertEqual(args?.path("request", "maxMessages")?.intValue, 25)

        transport.desk.send("session/follow", session: "s1", snapshot([said("hello", seq: 3)]))
        try await until("the snapshot") { conversation.loaded }
        XCTAssertFalse(conversation.loading)
        XCTAssertEqual(conversation.items.map(\.id), ["m3"])

        transport.desk.send("session/follow", session: "s1", eventItem(said("again", seq: 4)))
        try await until("the next event") { conversation.items.count == 2 }
    }

    func testAConversationOpenedOfflineIsFollowedOnceConnected() async throws {
        let transport = ScriptedTransport()
        let session = machine(transport)
        let conversation = session.conversation("s1")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(transport.desk.count("session/follow"), 0, "there is no connection to follow it on")
        XCTAssertTrue(conversation.loading)

        await connect(session, transport)
        try await until("the follow") { transport.desk.count("session/follow") == 1 }
    }

    // MARK: - Reconnecting

    /// The new snapshot replaces the window; it is not appended to it.
    func testAReconnectReplacesTheWindowWithAFreshSnapshot() async throws {
        let transport = ScriptedTransport()
        let session = machine(transport)
        await connect(session, transport)
        let conversation = session.conversation("s1")
        try await until("the follow") { transport.desk.count("session/follow") == 1 }
        transport.desk.send("session/follow", session: "s1", snapshot([said("first", seq: 3)]))
        try await until("the snapshot") { conversation.loaded }

        transport.desk.disconnectAll()
        await connect(session, transport)
        try await until("the follow again") { transport.desk.count("session/follow") == 2 }
        XCTAssertEqual(conversation.items.map(\.id), ["m3"], "what was held stays up until the new snapshot")

        transport.desk.send("session/follow", session: "s1", snapshot([said("first", seq: 3), said("missed", seq: 5)]))
        try await until("the new snapshot") { conversation.items.count == 2 }
        XCTAssertEqual(conversation.items.map(\.id), ["m3", "m5"])
        XCTAssertEqual(transport.desk.count("$events"), 2)
    }

    /// dsh restarting under a live tunnel ends every stream with
    /// `upstream-lost`; when the Bridle says it is back, they open again.
    func testDshComingBackReopensEverything() async throws {
        let transport = ScriptedTransport()
        let session = machine(transport)
        await connect(session, transport)
        _ = session.conversation("s1")
        try await until("the streams") { transport.desk.count("$events") == 1 && transport.desk.count("session/follow") == 1 }

        session.receiveForTesting(.harness(reachable: false, detail: "dsh stopped"))
        transport.desk.fail("$events", code: "upstream-lost")
        transport.desk.fail("session/follow", session: "s1", code: "upstream-lost")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(transport.desk.count("session/follow"), 1, "a lost upstream is not retried on its own")

        await transport.answer("session/list", .object(["items": .array([])]))
        session.receiveForTesting(.harness(reachable: true, detail: nil))
        try await until("everything again") { transport.desk.count("$events") == 2 && transport.desk.count("session/follow") == 2 }
    }

    // MARK: - Failures

    /// A conversation whose tail is over the frame ceiling is asked for again
    /// with half the messages, until it fits.
    func testASnapshotTooLargeForTheTunnelIsAskedForSmaller() async throws {
        let transport = ScriptedTransport()
        let session = machine(transport)
        await connect(session, transport)
        _ = session.conversation("s1")
        try await until("the follow") { transport.desk.count("session/follow") == 1 }

        transport.desk.fail("session/follow", session: "s1", code: "too-large")
        try await until("a smaller follow") { transport.desk.count("session/follow") == 2 }
        XCTAssertEqual(transport.desk.args("session/follow").last?.path("request", "maxMessages")?.intValue, 12)
    }

    func testAFollowTheMachineRefusesStopsLoadingAndSaysWhy() async throws {
        let transport = ScriptedTransport()
        let session = machine(transport)
        await connect(session, transport)
        let conversation = session.conversation("s1")
        try await until("the follow") { transport.desk.count("session/follow") == 1 }

        transport.desk.fail("session/follow", session: "s1", code: "session/not-found")
        try await until("loading to stop") { !conversation.loading }
        guard case .notice(let notice)? = conversation.items.last else { return XCTFail("no word on screen") }
        XCTAssertEqual(notice.kind, .failure)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(transport.desk.count("session/follow"), 1, "a refusal is not asked again")
    }

    /// Only so many conversations are held, and one let go stops being
    /// followed: otherwise dsh goes on sending it, and the relay carries it.
    func testALetGoConversationStopsBeingFollowed() async throws {
        let transport = ScriptedTransport()
        let session = machine(transport)
        await connect(session, transport)
        _ = session.conversation("s0")
        try await until("the follow") { transport.desk.count("session/follow") == 1 }
        for index in 1...8 { _ = session.conversation("s\(index)") }
        try await until("the oldest to be let go") { transport.desk.followEnded("s0") }
        XCTAssertFalse(transport.desk.followEnded("s8"))
    }

    // MARK: - Paging and streaming

    /// An older page is read against the same log the window came from: up to
    /// the window's cursor, before its first event.
    func testOlderHistoryIsReadFromTheSameLog() async throws {
        let transport = ScriptedTransport()
        let session = machine(transport)
        await connect(session, transport)
        let conversation = session.conversation("s1")
        try await until("the follow") { transport.desk.count("session/follow") == 1 }
        transport.desk.send("session/follow", session: "s1", snapshot([said("second", seq: 10), event("step/end", seq: 12, data: .emptyObject)], hasMore: true))
        try await until("the snapshot") { conversation.loaded }

        await transport.answer("session/page", .object([
            "records": .array([.object(["type": .string("event"), "event": said("first", seq: 4)])]),
            "hasMore": .bool(false),
        ]))
        await session.loadOlder(conversation)

        let asked = await transport.payloads("session/page").first
        XCTAssertEqual(asked?.path("request", "throughSeq")?.intValue, 12)
        XCTAssertEqual(asked?.path("request", "beforeSeq")?.intValue, 10)
        XCTAssertEqual(conversation.items.map(\.id), ["m4", "m10"])
        XCTAssertFalse(conversation.hasMore)
    }

    /// Chunks are held for a frame and folded together; the message that ends
    /// the step folds after them, never before — or the bubble would read its
    /// final text followed by the tail of its own stream.
    func testStreamedTextFoldsBeforeTheMessageThatEndsIt() async throws {
        let transport = ScriptedTransport()
        let session = machine(transport)
        await connect(session, transport)
        let conversation = session.conversation("s1")
        try await until("the follow") { transport.desk.count("session/follow") == 1 }
        transport.desk.send("session/follow", session: "s1", snapshot([event("turn/start", seq: 1, data: .object(["turn": 1]))]))

        let attempt = JSONValue.string("s1:1")
        transport.desk.send("session/follow", session: "s1", streamItem(.object([
            "type": .string("start"), "attemptId": attempt, "turn": 1, "step": 1, "revision": 1, "startedAfterSeq": 1,
        ])))
        for piece in ["Let", " me", " think"] {
            transport.desk.send("session/follow", session: "s1", streamItem(.object([
                "type": .string("chunk"), "attemptId": attempt, "index": 0, "time": 1,
                "chunk": .object(["type": .string("text-delta"), "index": 0, "text": .string(piece)]),
            ])))
        }
        transport.desk.send("session/follow", session: "s1", eventItem(event("assistant/message", seq: 2, data: .object([
            "turn": 1, "step": 1,
            "message": .object(["content": .array([.object(["type": .string("text"), "text": .string("Let me think about it.")])])]),
        ]))))
        transport.desk.send("session/follow", session: "s1", streamItem(.object([
            "type": .string("end"), "attemptId": attempt, "outcome": .object(["kind": .string("committed"), "seq": 2]),
        ])))

        try await until("the message") {
            if case .assistant(let bubble)? = conversation.items.first { return bubble.complete }
            return false
        }
        try await Task.sleep(for: .milliseconds(80))
        guard case .assistant(let bubble)? = conversation.items.first else { return XCTFail("no bubble") }
        XCTAssertEqual(bubble.text, "Let me think about it.")
        XCTAssertEqual(conversation.items.count, 1)
    }

    // MARK: - Sends and titles

    /// A send cut off after it was written may have arrived. It stays up until
    /// the machine's copy replaces it, instead of being reported as unsent.
    func testAnInterruptedSendIsNotReportedAsUnsent() async throws {
        let transport = ScriptedTransport()
        await transport.fail("session/prompt", code: "interrupted")
        let session = machine(transport)
        session.unconfirmedSendWait = .seconds(2)
        let conversation = session.conversation("s1")
        session.receiveForTesting(follow: snapshot([]), sessionId: "s1")

        let sending = Task { await session.send(sessionId: "s1", text: "ship it") }
        try await until("the prompt") { await transport.count("session/prompt") == 1 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(conversation.items.count, 1, "the message was taken back although it may have arrived")
        XCTAssertNil(session.problem)

        // The reconnect's snapshot: the machine did get it, under the id it was sent with.
        let requestId = await transport.payloads("session/prompt").first?.path("request", "requestId")?.stringValue
        XCTAssertNotNil(requestId)
        session.receiveForTesting(follow: snapshot([said("ship it", seq: 7, requestId: requestId)]), sessionId: "s1")
        await sending.value
        XCTAssertEqual(conversation.items.map(\.id), ["m7"])
        XCTAssertNil(session.problem, "a message that arrived was reported as not sent")
    }

    /// A rename made on this phone must not outrank the Mac's later ones.
    func testARenameHereDoesNotFreezeTheTitle() async throws {
        let transport = ScriptedTransport()
        await transport.answer("session/rename", .emptyObject)
        let session = machine(transport)
        let conversation = session.conversation("s1")
        await session.rename(sessionId: "s1", title: "From the phone")
        XCTAssertEqual(conversation.title, "From the phone")

        conversation.applyProjection(key: "title", value: .string("From the Mac"), seq: 90)
        XCTAssertEqual(conversation.title, "From the Mac")
    }

    /// A result that arrives before its call is not folded, and so must not
    /// spend its sequence number: re-delivered behind the call, it has to land.
    func testAnUnplacedResultCanLandWhenItsCallArrives() {
        let held = Conversation(sessionId: "s1")
        held.adopt(snapshot: snapshot([]))
        held.apply(event: toolResult("c9", seq: 21))
        held.apply(event: toolCall("c9", seq: 20))
        held.apply(event: toolResult("c9", seq: 21))

        guard case .tool(let card)? = held.items.last else { return XCTFail("no card") }
        XCTAssertFalse(card.running, "the result was spent before it had anywhere to land")
    }
}
