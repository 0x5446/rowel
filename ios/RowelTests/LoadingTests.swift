/// How a conversation gets loaded, and loaded again.
///
/// Opening a conversation is a race: the history page is on its way while the
/// live stream is already delivering, and the connection can drop halfway
/// through. Each case here is one way that race used to be lost — events
/// folded ahead of the history they belong behind, a page that failed while
/// offline and was never asked for again, a resync that refetched every
/// conversation ever opened.

import Observation
import XCTest
@testable import Rowel

/// A machine whose answers the test hands out one at a time.
private actor ScriptedTransport: HarnessTransport {
    private var answers: [String: [Result<JSONValue, CallError>]] = [:]
    private var waiting: [String: [CheckedContinuation<JSONValue, Error>]] = [:]
    private var held: Set<String> = []
    private(set) var calls: [String] = []

    /// Make calls to `method` with nothing queued wait for `release`, instead
    /// of failing at once as every other unscripted call does.
    func hold(_ method: String) {
        held.insert(method)
    }

    /// Queue an answer.
    func answer(_ method: String, _ value: JSONValue) {
        answers[method, default: []].append(.success(value))
    }

    func fail(_ method: String, code: String) {
        answers[method, default: []].append(.failure(CallError(code: code, message: code)))
    }

    /// Answer a call that is already waiting.
    func release(_ method: String, _ value: JSONValue) {
        guard var queue = waiting[method], !queue.isEmpty else { return answer(method, value) }
        queue.removeFirst().resume(returning: value)
        waiting[method] = queue
    }

    /// Fail a call that is already waiting.
    func releaseFailing(_ method: String, code: String) {
        guard var queue = waiting[method], !queue.isEmpty else { return fail(method, code: code) }
        queue.removeFirst().resume(throwing: CallError(code: code, message: code))
        waiting[method] = queue
    }

    func count(_ method: String) -> Int { calls.filter { $0 == method }.count }

    func call(_ method: String, _ payload: JSONValue) async throws -> JSONValue {
        calls.append(method)
        if var queue = answers[method], !queue.isEmpty {
            let next = queue.removeFirst()
            answers[method] = queue
            return try next.get()
        }
        guard held.contains(method) else { throw CallError(code: "not-found", message: "unscripted \(method)") }
        return try await withCheckedThrowingContinuation { waiting[method, default: []].append($0) }
    }

    func respond(rpcId: String, value: JSONValue) async throws -> JSONValue { .emptyObject }
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

    private func event(_ type: String, seq: Int, data: JSONValue) -> JSONValue {
        .object(["type": .string(type), "seq": .number(Double(seq)), "time": .number(1_700_000_000_000), "data": data])
    }

    private func live(_ event: JSONValue, session: String = "s1") -> TunnelSignal {
        .event(EventFrame(seq: 1, stream: .mux, frame: .object([
            "type": .string("server-request"),
            "payload": .object(["type": .string("session/event"), "sessionId": .string(session), "event": event]),
        ])))
    }

    private func page(_ events: [JSONValue], hasMore: Bool = false) -> JSONValue {
        .object(["events": .array(events.map { .object(["event": $0]) }), "hasMore": .bool(hasMore)])
    }

    private func said(_ text: String, seq: Int) -> JSONValue {
        event("user/message", seq: seq, data: .object([
            "id": .string("m\(seq)"),
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "source": .object(["kind": .string("user")]),
        ]))
    }

    private func toolCall(_ id: String, seq: Int) -> JSONValue {
        event("tool/call", seq: seq, data: .object(["callId": .string(id), "name": .string("Bash"), "arguments": .string("{}")]))
    }

    private func toolResult(_ id: String, seq: Int) -> JSONValue {
        event("tool/result", seq: seq, data: .object(["message": .object([
            "source": .object(["callId": .string(id)]),
            "content": .array([.object([
                "type": .string("tool-result"),
                "toolCallId": .string(id),
                "content": .array([.object(["type": .string("text"), "text": .string("done")])]),
            ])]),
        ])]))
    }

    private func until(_ what: String, _ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out waiting for \(what)")
    }

    /// Open a conversation that is running a tool. The live stream delivers
    /// the tool before the history page does; it has to end up *after* that
    /// history, not above it.
    func testLiveEventsThatBeatTheHistoryPageLandBehindIt() async throws {
        let transport = ScriptedTransport()
        await transport.hold("session.history")
        let session = machine(transport)
        let conversation = session.conversation("s1")
        try await until("the history request") { await transport.count("session.history") == 1 }

        session.receiveForTesting(live(toolCall("c1", seq: 10)))
        session.receiveForTesting(live(toolResult("c1", seq: 11)))
        await transport.release("session.history", page([said("run the tests", seq: 5), toolCall("c1", seq: 10)]))
        try await until("the page") { conversation.loaded }

        XCTAssertEqual(conversation.items.map(\.id), ["m5", "c1"], "the live tool was folded above the history it follows")
        guard case .tool(let card) = conversation.items.last else { return XCTFail("no tool card") }
        XCTAssertFalse(card.running, "the result that arrived live was lost")
        XCTAssertEqual(card.resultText, "done")
    }

    /// The tail page landed, then the connection dropped before the rest of
    /// the page did. Coming back online has to fetch the rest.
    func testAHalfLoadedConversationIsFinishedWhenTheConnectionReturns() async throws {
        let transport = ScriptedTransport()
        await transport.answer("session.history", page([said("latest", seq: 50)], hasMore: true))
        await transport.fail("session.history", code: "interrupted")
        let session = machine(transport)
        let conversation = session.conversation("s1")
        try await until("the tail and the failed top-up") { await transport.count("session.history") == 2 }
        try await until("the load to settle") { !conversation.loading }
        XCTAssertTrue(conversation.topUpOwed)

        await transport.answer("session.history", page([said("earlier", seq: 20)]))
        session.receiveForTesting(.status(.online(carrier: .relay, machine: "Mac", harnessUp: true)))
        try await until("the top-up") { await transport.count("session.history") == 3 }
        try await until("the earlier message") { conversation.items.count == 2 }

        XCTAssertEqual(conversation.items.map(\.id), ["m20", "m50"])
        XCTAssertFalse(conversation.topUpOwed)
    }

    /// The command list failed while offline, which left a typed `/permission`
    /// going to the model as words. It has to be asked for again.
    func testTheCommandListIsFetchedAgainAfterAnOutage() async throws {
        let transport = ScriptedTransport()
        await transport.answer("session.history", page([]))
        await transport.fail("commands/list", code: "disconnected")
        await transport.answer("skill.list", .object(["skills": .array([])]))
        let session = machine(transport)
        let conversation = session.conversation("s1")
        try await until("the first command request") { await transport.count("commands/list") == 1 }
        try await until("it to settle") { await transport.count("skill.list") == 1 }
        XCTAssertFalse(conversation.commandsKnown)

        await transport.answer("commands/list", .array([
            .object(["name": .string("permission"), "description": .string("Change access")]),
        ]))
        session.receiveForTesting(.status(.online(carrier: .relay, machine: "Mac", harnessUp: true)))
        try await until("the retry") { conversation.commandsKnown }

        XCTAssertEqual(conversation.machineLine(for: "/permission read-only"), "/permission read-only")
    }

    /// A resync refetches the conversation on screen, not every one ever opened.
    func testAResyncRefetchesOnlyTheConversationOnScreen() async throws {
        let transport = ScriptedTransport()
        for _ in 0..<3 { await transport.answer("session.history", page([])) }
        await transport.answer("session.list", .object(["items": .array([])]))
        let session = machine(transport)
        _ = session.conversation("a")
        _ = session.conversation("b")
        let onScreen = session.conversation("c")
        try await until("three opens") { await transport.count("session.history") == 3 }

        await transport.answer("session.history", page([said("fresh", seq: 1)], hasMore: false))
        session.receiveForTesting(.resync(from: 0))
        try await until("the refetch") { await transport.count("session.history") == 4 }
        try await Task.sleep(for: .milliseconds(100))

        let fetched = await transport.count("session.history")
        XCTAssertEqual(fetched, 4, "every conversation ever opened was refetched")
        XCTAssertTrue(session.conversation("c") === onScreen, "the one on screen was replaced instead of refreshed")
    }

    /// Cards held from before a reconnect may have been answered elsewhere, or
    /// died with a restarted dsh. The machine re-sends the live ones right
    /// after the handshake; the rest must go.
    func testCardsFromBeforeAReconnectAreDropped() async {
        let session = machine(ScriptedTransport())
        session.receiveForTesting(.event(EventFrame(seq: 0, stream: .mux, frame: .object([
            "rpcId": .string("r1"),
            "payload": .object([
                "type": .string("approval/requested"), "sessionId": .string("s1"),
                "approvalId": .string("a1"), "toolName": .string("Bash"),
            ]),
        ]))))
        XCTAssertNotNil(session.approvals["s1"])

        session.receiveForTesting(.handshake(host: nil, harness: nil, direct: nil))

        XCTAssertNil(session.approvals["s1"], "a card from before the reconnect outlived it")
    }

    /// A send cut off after it was written may have arrived. It stays up until
    /// the machine's copy replaces it, instead of being reported as unsent.
    func testAnInterruptedSendIsNotReportedAsUnsent() async throws {
        let transport = ScriptedTransport()
        await transport.answer("session.history", page([]))
        await transport.fail("session.prompt", code: "interrupted")
        let session = machine(transport)
        session.unconfirmedSendWait = .seconds(2)
        let conversation = session.conversation("s1")
        try await until("the page") { conversation.loaded }

        let sending = Task { await session.send(sessionId: "s1", text: "ship it") }
        try await until("the prompt") { await transport.count("session.prompt") == 1 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(conversation.items.count, 1, "the message was taken back although it may have arrived")
        XCTAssertNil(session.problem)

        // The reconnect's replay: the machine did get it.
        session.receiveForTesting(live(said("ship it", seq: 7)))
        await sending.value
        XCTAssertEqual(conversation.items.map(\.id), ["m7"])
        XCTAssertNil(session.problem, "a message that arrived was reported as not sent")
    }

    /// A rename made on this phone must not outrank the Mac's later ones.
    func testARenameHereDoesNotFreezeTheTitle() async throws {
        let transport = ScriptedTransport()
        await transport.answer("session.history", page([]))
        await transport.answer("session.rename", .emptyObject)
        let session = machine(transport)
        let conversation = session.conversation("s1")
        await session.rename(sessionId: "s1", title: "From the phone")
        XCTAssertEqual(conversation.title, "From the phone")

        conversation.applyProjection(key: "title", value: .string("From the Mac"), seq: 90)
        XCTAssertEqual(conversation.title, "From the Mac")
    }

    /// The Bridle thins a history page by dropping the chunks of a message the
    /// page already holds whole, so the tail page can start at that message's
    /// `assistant/message` while the chunks that built it sit just before it.
    /// The page that fills in above then carries those chunks too, and folded
    /// them into a second, forever-streaming copy of the same bubble.
    func testTheChunksOfAMessageAlreadyHeldDoNotBecomeASecondBubble() {
        let held = Conversation(sessionId: "s1")
        held.absorb(page: page([
            event("assistant/message", seq: 30, data: .object([
                "turn": 1, "step": 0,
                "message": .object(["content": .array([.object(["type": .string("text"), "text": .string("all of it")])])]),
            ])),
        ], hasMore: true), prepend: false)
        held.absorb(page: page([
            said("go", seq: 10),
            event("assistant/chunk", seq: 11, data: .object([
                "turn": 1, "step": 0, "chunk": .object(["type": .string("text-delta"), "text": .string("all ")]),
            ])),
            event("assistant/chunk", seq: 12, data: .object([
                "turn": 1, "step": 0, "chunk": .object(["type": .string("text-delta"), "text": .string("of")]),
            ])),
        ]), prepend: true)

        XCTAssertEqual(held.items.map(\.id), ["m10", "a1.0"], "the same bubble is on screen twice")
        guard case .assistant(let bubble) = held.items.last else { return XCTFail("no bubble") }
        XCTAssertTrue(bubble.complete)
        XCTAssertEqual(bubble.text, "all of it")
    }

    /// The connection came back while the load it should replace was still
    /// out; that load then failed. The reconnect's retry must not be lost.
    func testAReconnectThatBeatsAFailingLoadStillRetries() async throws {
        let transport = ScriptedTransport()
        await transport.hold("session.history")
        let session = machine(transport)
        let conversation = session.conversation("s1")
        try await until("the first request") { await transport.count("session.history") == 1 }

        session.receiveForTesting(.status(.online(carrier: .relay, machine: "Mac", harnessUp: true)))
        try await Task.sleep(for: .milliseconds(50))
        await transport.releaseFailing("session.history", code: "interrupted")
        try await until("the retry") { await transport.count("session.history") == 2 }
        await transport.release("session.history", page([said("here", seq: 3)]))
        try await until("the page") { conversation.loaded }

        XCTAssertEqual(conversation.items.map(\.id), ["m3"])
    }

    /// A resync while the first load is out: the old page must not land in the
    /// refetched conversation, whichever answer comes back first.
    func testAPageFromBeforeAResyncIsDropped() async throws {
        let transport = ScriptedTransport()
        await transport.hold("session.history")
        await transport.answer("session.list", .object(["items": .array([])]))
        let session = machine(transport)
        let conversation = session.conversation("s1")
        try await until("the first request") { await transport.count("session.history") == 1 }

        session.receiveForTesting(.resync(from: 0))
        // Whether the refetch goes out at once or waits for the load in flight
        // is the implementation's business; either way the old answer lands
        // after the reset.
        for _ in 0..<20 where await transport.count("session.history") < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        await transport.release("session.history", page([said("stale", seq: 1)]))
        try await until("the refetch") { await transport.count("session.history") == 2 }
        await transport.release("session.history", page([said("fresh", seq: 9)]))
        try await until("the fresh page") { conversation.loaded && !conversation.items.isEmpty }
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(conversation.items.map(\.id), ["m9"], "a page from before the resync was folded into it")
    }

    /// A history that failed outright must not keep holding the live stream:
    /// the conversation would look frozen until the next successful load.
    func testLiveEventsFlowAfterTheHistoryFails() async throws {
        let transport = ScriptedTransport()
        await transport.fail("session.history", code: "internal")
        let session = machine(transport)
        let conversation = session.conversation("s1")
        try await until("the failure") { !conversation.loading }

        session.receiveForTesting(live(said("still going", seq: 4)))
        XCTAssertTrue(conversation.items.contains { $0.id == "m4" }, "the live stream stayed held behind a page that is not coming")
    }

    /// A result that arrives before its call is not folded, and so must not
    /// spend its sequence number: re-delivered behind the call, it has to land.
    func testAnUnplacedResultCanLandWhenItsCallArrives() {
        let held = Conversation(sessionId: "s1")
        held.absorb(page: page([]), prepend: false)
        held.apply(event: toolResult("c9", seq: 21), view: nil)
        held.apply(event: toolCall("c9", seq: 20), view: nil)
        held.apply(event: toolResult("c9", seq: 21), view: nil)

        guard case .tool(let card)? = held.items.last else { return XCTFail("no card") }
        XCTAssertFalse(card.running, "the result was spent before it had anywhere to land")
    }

    /// The first load failed, live events were shown, and a later load then
    /// succeeded. Its page is the history those events belong behind; appended
    /// after them, the conversation read backwards.
    func testALoadThatSucceedsAfterAFailureKeepsTheOrder() async throws {
        let transport = ScriptedTransport()
        await transport.fail("session.history", code: "internal")
        let session = machine(transport)
        let conversation = session.conversation("s1")
        try await until("the failure") { await transport.count("session.history") == 1 }
        try await until("it to settle") { !conversation.loading }
        session.receiveForTesting(live(said("latest", seq: 8)))

        await transport.answer("session.history", page([said("earlier", seq: 2), said("latest", seq: 8)]))
        session.receiveForTesting(.status(.online(carrier: .relay, machine: "Mac", harnessUp: true)))
        try await until("the reload") { conversation.loaded }

        XCTAssertEqual(conversation.items.filter { $0.id.hasPrefix("m") }.map(\.id), ["m2", "m8"], "history landed behind the live message")
    }

    /// Scrolling back while a resync lands: the older page asked for before
    /// the reset must not stand in for the refetch. It used to mark the
    /// conversation loaded, so the tail was never fetched again and every live
    /// event after it stayed held.
    func testAnOlderPageInFlightDuringAResyncIsDropped() async throws {
        let transport = ScriptedTransport()
        await transport.answer("session.history", page([said("tail", seq: 50)], hasMore: true))
        await transport.answer("session.history", page([said("above", seq: 40)], hasMore: true))
        await transport.answer("session.list", .object(["items": .array([])]))
        let session = machine(transport)
        let conversation = session.conversation("s1")
        try await until("the opening page") { await transport.count("session.history") == 2 && !conversation.loading }

        await transport.hold("session.history")
        let older = Task { await session.loadOlder(conversation) }
        try await until("the scroll-back request") { await transport.count("session.history") == 3 }
        session.receiveForTesting(.resync(from: 0))
        await transport.release("session.history", page([said("much older", seq: 10)], hasMore: true))
        await older.value
        try await until("the refetch") { await transport.count("session.history") == 4 }
        await transport.release("session.history", page([said("fresh tail", seq: 60)]))
        try await until("the fresh tail") { conversation.items.contains { $0.id == "m60" } }

        XCTAssertFalse(conversation.items.contains { $0.id == "m10" }, "a page from before the resync was folded into it")
        session.receiveForTesting(live(said("after", seq: 61)))
        XCTAssertTrue(conversation.items.contains { $0.id == "m61" }, "live events stayed held after the resync")
    }

    /// A conversation dropped by a resync while its load was out, and opened
    /// again: the new one must load, not wait on the old one's load.
    func testAConversationReopenedAfterAResyncLoadsOnItsOwn() async throws {
        let transport = ScriptedTransport()
        await transport.hold("session.history")
        await transport.answer("session.list", .object(["items": .array([])]))
        let session = machine(transport)
        _ = session.conversation("a")
        _ = session.conversation("b")
        try await until("both opening requests") { await transport.count("session.history") == 2 }

        session.receiveForTesting(.resync(from: 0))   // "b" is on screen; "a" is dropped
        let reopened = session.conversation("a")
        try await until("the reopened conversation's own request") { await transport.count("session.history") >= 3 }
        await transport.release("session.history", page([said("old a", seq: 1)]))
        await transport.release("session.history", page([said("b", seq: 1)]))
        await transport.release("session.history", page([said("new a", seq: 2)]))
        try await until("the reopened conversation to load") { reopened.loaded }
        XCTAssertTrue(reopened.items.contains { $0.id == "m2" })
    }
}
