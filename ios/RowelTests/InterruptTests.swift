/// The two moments the machine stops and waits for a person.
///
/// Untested until an `ask_user_question` went unanswered on a phone while the
/// web UI showed a card with three options on it. The payloads here are the
/// ones that produced that — captured from the wire, not written from the
/// method names — because the failure was never in the rendering and could
/// only ever have been found by folding what a real dsh actually sends.

import XCTest
@testable import Rowel

/// Keeps every answer sent, and refuses on command.
private actor AnswerTransport: CallOnlyTransport {
    private(set) var sent: [(endpoint: String, args: JSONValue)] = []
    var refuse = false

    func refuseAll() { refuse = true }

    func call(_ endpoint: String, _ args: JSONValue) async throws -> JSONValue {
        sent.append((endpoint, args))
        if refuse { throw CallError(code: "disconnected", message: "The connection dropped.") }
        return .emptyObject
    }
}

@MainActor
final class InterruptTests: XCTestCase {
    private let sessionId = "session-1f55260e-4ce5-45a5-8fff-78e508071670"

    /// dsh's `user-questions/request` on `$events`, as recorded live
    /// (docs/dsh-0.2-protocol.md §5.3), apart from shortened prose.
    private func questionFrame() -> JSONValue {
        .object([
            "type": .string("waterfall"),
            "event": .string("user-questions/request"),
            "eventId": .string("cf6f20c2-a77a-4d75-bf3b-9b872198460b"),
            "agentId": .string(sessionId),
            "request": .object([
                "questions": .array([
                    .object([
                        "id": .string("hitl-confirm"),
                        "question": .string("是否保持 Exa 作为唯一搜索提供方？"),
                        "header": .string("HITL 确认"),
                        "options": .array([
                            .object(["label": .string("保持 Exa（推荐）"), "description": .string("维持当前配置。")]),
                            .object(["label": .string("换回 DeepSeek official"), "description": .string("需先配置 key。")]),
                            .object(["label": .string("两个都留，临时切换"), "description": .string("记下切回步骤。")]),
                        ]),
                    ]),
                ]),
            ]),
        ])
    }

    /// dsh's `approval/request`, as recorded live (§5.2).
    private func approvalFrame() -> JSONValue {
        .object([
            "type": .string("waterfall"),
            "event": .string("approval/request"),
            "eventId": .string("3824b6e1-71ca-4462-bc64-ab7aa98e8b9c"),
            "agentId": .string(sessionId),
            "request": .object([
                "toolName": .string("bash"),
                "callId": .string("call_00_43jk9exuu76uznsuc7wvypqf"),
                "reason": .string("escalate sandbox to danger-full-access: protocol test"),
                "displayReason": .object([
                    "en": .string("Allow this operation with danger-full-access permissions: protocol test"),
                    "zh": .string("允许本次操作使用 danger-full-access 权限：protocol test"),
                ]),
            ]),
        ])
    }

    func testAQuestionFromTheMachineBecomesACardForThatSession() {
        let session = makeSession()
        session.receiveForTesting(events: questionFrame())

        guard let asked = session.questions[sessionId] else {
            return XCTFail("no question card; the machine is waiting and the phone shows nothing")
        }
        XCTAssertEqual(asked.id, "cf6f20c2-a77a-4d75-bf3b-9b872198460b", "the eventId is what an answer names")
        XCTAssertEqual(asked.clientId, "test-client", "and the answer is sent as the client that was asked")
        XCTAssertEqual(asked.items.count, 1)
        XCTAssertEqual(asked.items[0].header, "HITL 确认")
        XCTAssertEqual(asked.items[0].options.map(\.label), ["保持 Exa（推荐）", "换回 DeepSeek official", "两个都留，临时切换"])
        XCTAssertFalse(asked.items[0].isPlanReview)
    }

    func testAnsweringElsewhereClearsTheCard() {
        let session = makeSession()
        session.receiveForTesting(events: questionFrame())
        session.receiveForTesting(events: approvalFrame())
        XCTAssertNotNil(session.questions[sessionId])

        session.receiveForTesting(events: .object([
            "type": .string("cancel"),
            "eventId": .string("cf6f20c2-a77a-4d75-bf3b-9b872198460b"),
        ]))
        XCTAssertNil(session.questions[sessionId], "the web UI answered it; the phone must stop offering to")
        XCTAssertNotNil(session.approvals[sessionId], "a cancel names one request, not the session")
    }

    func testAnApprovalFromTheMachineBecomesACard() {
        let session = makeSession()
        session.receiveForTesting(events: approvalFrame())

        guard let asked = session.approvals[sessionId] else {
            return XCTFail("no approval card; the agent is blocked and the phone shows nothing")
        }
        XCTAssertEqual(asked.toolName, "bash")
        XCTAssertEqual(asked.approvalId, "call_00_43jk9exuu76uznsuc7wvypqf", "the call it is for, to match the tool card")
        XCTAssertEqual(asked.reason, "Allow this operation with danger-full-access permissions: protocol test")
    }

    /// A new connection is a new `$events` client, and dsh re-sends it every
    /// request still waiting; cards from before must not outlive the old one.
    func testAHandshakeClearsCardsTheMachineWillResend() {
        let session = makeSession()
        session.receiveForTesting(events: approvalFrame())
        session.receiveForTesting(.handshake(.test(dshReachable: false)))
        XCTAssertNil(session.approvals[sessionId])
    }

    // MARK: - Answering

    /// The answer goes to `$events/result` as the client that was asked, naming
    /// the request — docs/dsh-0.2-protocol.md §5.4, keys exactly.
    func testAnApprovalIsAnsweredAsTheClientThatWasAsked() async {
        let transport = AnswerTransport()
        let session = makeSession(transport)
        session.receiveForTesting(events: approvalFrame())
        guard let asked = session.approvals[sessionId] else { return XCTFail("no card") }

        await session.answer(approval: asked, allow: true)

        let sent = await transport.sent
        XCTAssertEqual(sent.map(\.endpoint), ["$events/result"])
        XCTAssertEqual(sent.first?.args, .object([
            "clientId": .string("test-client"),
            "eventId": .string("3824b6e1-71ca-4462-bc64-ab7aa98e8b9c"),
            "outcome": .object(["kind": .string("result"), "value": .string("allowed-once")]),
        ]))
        XCTAssertNil(session.approvals[sessionId])
    }

    func testAQuestionIsAnsweredWithEveryChoice() async {
        let transport = AnswerTransport()
        let session = makeSession(transport)
        session.receiveForTesting(events: questionFrame())
        guard let asked = session.questions[sessionId] else { return XCTFail("no card") }

        await session.answer(question: asked, answers: ["hitl-confirm": QuestionAnswer(selected: ["保持 Exa（推荐）"])])

        let sent = await transport.sent.first?.args
        XCTAssertEqual(sent?["eventId"]?.stringValue, "cf6f20c2-a77a-4d75-bf3b-9b872198460b")
        XCTAssertEqual(sent?.path("outcome", "value"), .object(["answers": .array([
            .object(["id": .string("hitl-confirm"), "selected": .array([.string("保持 Exa（推荐）")])]),
        ])]))
    }

    /// An answer that did not get through puts the card back — unless a new
    /// `$events` client has started meanwhile, which is sent its own.
    func testAFailedAnswerComesBackOnlyToTheSameClient() async {
        let transport = AnswerTransport()
        await transport.refuseAll()
        let session = makeSession(transport)
        session.receiveForTesting(events: approvalFrame())
        guard let asked = session.approvals[sessionId] else { return XCTFail("no card") }
        await session.answer(approval: asked, allow: false)
        XCTAssertEqual(session.approvals[sessionId], asked, "the person has to be able to try again")
        XCTAssertNotNil(session.problem)

        session.receiveForTesting(events: .object(["type": .string("ready"), "clientId": .string("the-next-client")]))
        XCTAssertNil(session.approvals[sessionId], "a new client is re-sent what is still waiting; the old cards go")
        await session.answer(approval: asked, allow: false)
        XCTAssertNil(session.approvals[sessionId], "the old client's card must not come back over the new one")
    }

    /// dsh restarting under a live tunnel takes its `$events` client with it.
    func testDshGoingAwayTakesTheCardsWithIt() {
        let session = makeSession()
        session.receiveForTesting(events: approvalFrame())
        session.receiveForTesting(.harness(reachable: false, detail: "dsh stopped"))
        XCTAssertNil(session.approvals[sessionId])
    }

    private func makeSession(_ transport: (any HarnessTransport)? = nil) -> MachineSession {
        let bundle = PairingBundle(
            relay: "https://relay.invalid", direct: nil, device: "device-1",
            key: "", token: "", name: "Test Mac"
        )
        let suite = UserDefaults(suiteName: "interrupt-tests-\(UUID().uuidString)")!
        return MachineSession(
            machine: PairedMachine(bundle: bundle),
            identity: .generate(),
            deviceName: "Test iPhone",
            clientVersion: "rowel-tests/1",
            pairingToken: nil,
            notifier: Notifier(center: nil),
            defaults: suite,
            transport: transport
        )
    }
}
