/// The fold, and the parsing around it.
///
/// `Conversation` turns the harness's append-only event log into what the screen
/// shows. It is the piece most likely to be wrong in a way nobody notices — a
/// duplicated message, a bubble that never stops streaming, a tool card that
/// loses its result — so these tests drive it with the same event shapes the
/// machine actually sends.

import XCTest
@testable import Rowel

@MainActor
final class ConversationFoldTests: XCTestCase {
    private func conversation() -> Conversation {
        Conversation(sessionId: "s1")
    }

    private func event(_ type: String, seq: Int, data: JSONValue = .emptyObject, time: Double = 1_700_000_000_000) -> JSONValue {
        .object([
            "type": .string(type),
            "seq": .number(Double(seq)),
            "time": .number(time),
            "data": data,
        ])
    }

    private func text(_ value: String) -> JSONValue {
        .array([.object(["type": .string("text"), "text": .string(value)])])
    }

    // MARK: - Messages

    /// A queued message that the machine has spoken must leave the strip.
    ///
    /// dsh clears the queue with an empty `session/queue` snapshot when it
    /// claims a message, but that snapshot is transient — no call re-asks for
    /// it — and one missed reconnect window left the strip offering to
    /// promote a message whose answer was already on screen above it. The
    /// `user/message` fold is the claim, so it retires the strip copy itself.
    func testAClaimedMessageLeavesTheQueueStrip() {
        let held = conversation()
        held.applyQueue([.object([
            "id": .string("q1"),
            "placement": .string("queued"),
            "message": .object(["content": text("能搜索个美股信息看看不")]),
        ])])
        XCTAssertEqual(held.queue.count, 1)

        held.apply(event: event("user/message", seq: 5, data: .object([
            "id": .string("m5"),
            "content": text("能搜索个美股信息看看不"),
            "source": .object(["kind": .string("user")]),
        ])), view: nil)

        XCTAssertEqual(held.queue.count, 0, "the transcript says it was heard; the strip may not keep offering it")
        XCTAssertEqual(held.items.count, 1)
    }

    /// And one claim retires one entry, not every copy of the same words.
    func testAClaimRetiresOnlyOneQueueEntry() {
        let held = conversation()
        held.applyQueue([
            .object(["id": .string("q1"), "placement": .string("queued"), "message": .object(["content": text("再试一次")])]),
            .object(["id": .string("q2"), "placement": .string("queued"), "message": .object(["content": text("再试一次")])]),
        ])
        held.apply(event: event("user/message", seq: 5, data: .object([
            "id": .string("m5"),
            "content": text("再试一次"),
            "source": .object(["kind": .string("user")]),
        ])), view: nil)
        XCTAssertEqual(held.queue.map(\.id), ["q2"])
    }


    func testUserAndAssistantMessagesRender() {
        let held = conversation()
        held.apply(event: event("user/message", seq: 1, data: .object([
            "id": .string("m1"),
            "content": text("hello"),
            "source": .object(["kind": .string("user")]),
        ])), view: nil)
        held.apply(event: event("assistant/message", seq: 2, data: .object([
            "turn": 1, "step": 0,
            "message": .object(["content": text("hi back")]),
        ])), view: nil)

        XCTAssertEqual(held.items.count, 2)
        guard case .user(let user) = held.items[0], case .assistant(let assistant) = held.items[1] else {
            return XCTFail("unexpected item kinds")
        }
        XCTAssertEqual(user.text, "hello")
        XCTAssertFalse(user.synthetic)
        XCTAssertEqual(assistant.text, "hi back")
        XCTAssertTrue(assistant.complete)
    }

    /// Chunks build a bubble; the final message replaces it rather than appending
    /// a second copy.
    func testChunksBuildOneBubbleThenFinalise() {
        let held = conversation()
        for (index, piece) in ["Let", " me", " think"].enumerated() {
            held.apply(event: event("assistant/chunk", seq: index + 1, data: .object([
                "turn": 1, "step": 0,
                "chunk": .object(["type": .string("text-delta"), "text": .string(piece)]),
            ])), view: nil)
        }
        XCTAssertEqual(held.items.count, 1)
        guard case .assistant(let streaming) = held.items[0] else { return XCTFail("expected a bubble") }
        XCTAssertEqual(streaming.text, "Let me think")
        XCTAssertFalse(streaming.complete)

        held.apply(event: event("assistant/message", seq: 4, data: .object([
            "turn": 1, "step": 0,
            "message": .object(["content": text("Let me think about it.")]),
        ])), view: nil)
        XCTAssertEqual(held.items.count, 1)
        guard case .assistant(let finished) = held.items[0] else { return XCTFail("expected a bubble") }
        XCTAssertEqual(finished.text, "Let me think about it.")
        XCTAssertTrue(finished.complete)
    }

    /// The same event arriving twice — a history page that overlaps the live
    /// stream — must not render twice.
    func testDuplicateSequenceIsIgnored() {
        let held = conversation()
        let message = event("user/message", seq: 9, data: .object([
            "id": .string("m1"),
            "content": text("once"),
            "source": .object(["kind": .string("user")]),
        ]))
        held.apply(event: message, view: nil)
        held.apply(event: message, view: nil)
        XCTAssertEqual(held.items.count, 1)
    }

    /// A step that only called tools produces an empty assistant message. Leaving
    /// the bubble would put a gap above the tool cards.
    func testEmptyAssistantStepLeavesNoBubble() {
        let held = conversation()
        held.apply(event: event("assistant/chunk", seq: 1, data: .object([
            "turn": 1, "step": 0,
            "chunk": .object(["type": .string("reasoning-delta"), "text": .string("hmm")]),
        ])), view: nil)
        held.apply(event: event("assistant/message", seq: 2, data: .object([
            "turn": 1, "step": 0,
            "message": .object(["content": .array([])]),
        ])), view: nil)
        XCTAssertTrue(held.items.isEmpty)
    }

    /// Injected context is real model input and must be shown, but it did not come
    /// from the person and must not look like it did.
    func testSyntheticUserMessageIsMarked() {
        let held = conversation()
        held.apply(event: event("user/message", seq: 1, data: .object([
            "id": .string("m1"),
            "content": text("<file>...</file>"),
            "source": .object(["kind": .string("system"), "summary": .string("AGENTS.md")]),
        ])), view: nil)
        guard case .user(let user) = held.items.first else { return XCTFail("expected an item") }
        XCTAssertTrue(user.synthetic)
        XCTAssertEqual(user.text, "AGENTS.md")
    }

    /// A tool result reaches the log as `tool/result`. One arriving as a user
    /// message is a duplicate of a card already on screen.
    func testToolSourcedUserMessageIsDropped() {
        let held = conversation()
        held.apply(event: event("user/message", seq: 1, data: .object([
            "content": text("tool output"),
            "source": .object(["kind": .string("tool")]),
        ])), view: nil)
        XCTAssertTrue(held.items.isEmpty)
    }

    // MARK: - Tools

    func testToolCallAndResultShareOneCard() {
        let held = conversation()
        held.apply(event: event("tool/call", seq: 1, data: .object([
            "callId": .string("c1"),
            "name": .string("bash"),
            "arguments": .string("{\"command\":\"ls\"}"),
        ])), view: .object([
            "for": .string("call"),
            "view": .object(["card": .string("terminal"), "title": .string("ls"), "cwd": .string("/tmp")]),
        ]))

        guard case .tool(let pending) = held.items.first else { return XCTFail("expected a card") }
        XCTAssertTrue(pending.running)
        XCTAssertEqual(pending.headline, "ls")

        held.apply(event: event("tool/result", seq: 2, data: .object([
            "message": .object([
                "source": .object(["callId": .string("c1")]),
                "content": .array([.object([
                    "type": .string("tool-result"),
                    "toolCallId": .string("c1"),
                    "content": text("a.txt"),
                ])]),
            ]),
        ])), view: .object([
            "for": .string("result"),
            "view": .object(["card": .string("terminal"), "output": .string("a.txt"), "exitCode": 0]),
        ]))

        XCTAssertEqual(held.items.count, 1)
        guard case .tool(let done) = held.items[0] else { return XCTFail("expected a card") }
        XCTAssertFalse(done.running)
        XCTAssertFalse(done.failed)
        // An omitted title at result time means "keep the one the call set".
        XCTAssertEqual(done.headline, "ls")
        guard case .terminal(_, _, let output, let exit) = done.presentation else { return XCTFail("expected terminal") }
        XCTAssertEqual(output, "a.txt")
        XCTAssertEqual(exit, 0)
    }

    func testAnsweredQuestionKeepsTheChoiceInTheTranscript() {
        // The shape dsh logs for `ask_user_question`: questions in the call's
        // arguments, the person's answer as JSON text in the result, and no
        // render intent for either — so it fell through to a generic card that
        // showed `{"answers":[…]}` instead of what was asked and what was picked.
        let held = conversation()
        let arguments = #"{"questions":[{"id":"quota_scope","header":"Scope","question":"Which quota?","options":[{"label":"Session context","description":"Tokens left in this session."},{"label":"Provider balance"}]}]}"#
        held.apply(event: event("tool/call", seq: 1, data: .object([
            "callId": .string("q1"),
            "name": .string("ask_user_question"),
            "arguments": .string(arguments),
        ])), view: nil)

        guard case .tool(let asked) = held.items.first,
              case .question(let items, let pending) = asked.presentation
        else { return XCTFail("expected a question card") }
        XCTAssertEqual(items.map(\.question), ["Which quota?"])
        XCTAssertEqual(items.first?.options.map(\.label), ["Session context", "Provider balance"])
        XCTAssertNil(pending, "nothing is answered until the result lands")
        XCTAssertEqual(asked.headline, "Scope")

        held.apply(event: event("tool/result", seq: 2, data: .object([
            "message": .object([
                "source": .object(["callId": .string("q1")]),
                "content": .array([.object([
                    "type": .string("tool-result"),
                    "toolCallId": .string("q1"),
                    "content": text(#"{"answers":[{"id":"quota_scope","selected":["Session context"],"custom":"and the weekly cap"}]}"#),
                ])]),
            ]),
        ])), view: nil)

        XCTAssertEqual(held.items.count, 1, "the answer lands on the same card")
        guard case .tool(let answered) = held.items[0],
              case .question(_, let answers) = answered.presentation
        else { return XCTFail("expected the question card to survive the result") }
        XCTAssertFalse(answered.running)
        XCTAssertEqual(answers?["quota_scope"]?.selected, ["Session context"])
        XCTAssertEqual(answers?["quota_scope"]?.custom, "and the weekly cap")
    }

    func testQuestionWithUnreadableArgumentsStaysGeneric() {
        let held = conversation()
        held.apply(event: event("tool/call", seq: 1, data: .object([
            "callId": .string("q2"),
            "name": .string("ask_user_question"),
            "arguments": .string("not json"),
        ])), view: nil)
        guard case .tool(let card) = held.items.first else { return XCTFail("expected a card") }
        guard case .generic = card.presentation else { return XCTFail("unreadable arguments keep the generic card") }
    }

    func testFailedToolIsMarked() {
        let held = conversation()
        held.apply(event: event("tool/call", seq: 1, data: .object([
            "callId": .string("c1"), "name": .string("read"),
        ])), view: nil)
        held.apply(event: event("tool/result", seq: 2, data: .object([
            "message": .object([
                "content": .array([.object([
                    "toolCallId": .string("c1"),
                    "isError": .bool(true),
                    "content": text("no such file"),
                ])]),
            ]),
        ])), view: nil)
        guard case .tool(let card) = held.items[0] else { return XCTFail("expected a card") }
        XCTAssertTrue(card.failed)
        XCTAssertEqual(card.resultText, "no such file")
    }

    /// A result whose call was never seen — the call is on an older history page —
    /// must be dropped rather than creating a card with no context.
    func testOrphanResultIsIgnored() {
        let held = conversation()
        held.apply(event: event("tool/result", seq: 1, data: .object([
            "message": .object(["content": .array([.object(["toolCallId": .string("ghost")])])]),
        ])), view: nil)
        XCTAssertTrue(held.items.isEmpty)
    }

    // MARK: - Turn boundaries

    /// A turn can end without a final message — cancelled, or a provider error.
    /// A bubble left streaming would claim the answer is still coming.
    func testTurnEndCompletesStreamingBubbles() {
        let held = conversation()
        held.apply(event: event("turn/start", seq: 1), view: nil)
        held.apply(event: event("assistant/chunk", seq: 2, data: .object([
            "turn": 1, "step": 0,
            "chunk": .object(["type": .string("text-delta"), "text": .string("part")]),
        ])), view: nil)
        held.apply(event: event("tool/call", seq: 3, data: .object([
            "callId": .string("c1"), "name": .string("bash"),
        ])), view: nil)
        XCTAssertTrue(held.running)

        held.apply(event: event("turn/end", seq: 4, data: .object([
            "reason": .object(["kind": .string("cancelled"), "message": .string("You stopped it.")]),
        ])), view: nil)

        XCTAssertFalse(held.running)
        guard case .assistant(let bubble) = held.items[0], case .tool(let card) = held.items[1] else {
            return XCTFail("unexpected item kinds")
        }
        XCTAssertTrue(bubble.complete)
        XCTAssertFalse(card.running)
        guard case .notice(let notice) = held.items[2] else { return XCTFail("expected a notice") }
        XCTAssertEqual(notice.text, "You stopped it.")
        XCTAssertEqual(notice.kind, .failure)
    }

    func testSuccessfulTurnEndAddsNoNotice() {
        let held = conversation()
        held.apply(event: event("turn/end", seq: 1, data: .object([
            "reason": .object(["kind": .string("success")]),
        ])), view: nil)
        XCTAssertTrue(held.items.isEmpty)
    }

    /// An event type this build has never heard of must render nothing, not a
    /// placeholder. Plugins add event types and a client that guessed would draw
    /// noise into every transcript.
    func testUnknownEventIsSilent() {
        let held = conversation()
        held.apply(event: event("plugin/something-new", seq: 1, data: .object(["x": 1])), view: nil)
        XCTAssertTrue(held.items.isEmpty)
    }

    // MARK: - History paging

    func testOlderPagePrependsInOrder() {
        let held = conversation()
        held.absorb(page: .object([
            "events": .array([
                .object(["event": event("user/message", seq: 10, data: .object([
                    "id": .string("m10"), "content": text("second"), "source": .object(["kind": .string("user")]),
                ]))]),
            ]),
            "hasMore": .bool(true),
        ]), prepend: false)
        XCTAssertEqual(held.oldestSeq, 10)
        XCTAssertTrue(held.hasMore)

        held.absorb(page: .object([
            "events": .array([
                .object(["event": event("user/message", seq: 4, data: .object([
                    "id": .string("m4"), "content": text("first"), "source": .object(["kind": .string("user")]),
                ]))]),
            ]),
            "hasMore": .bool(false),
        ]), prepend: true)

        XCTAssertEqual(held.items.count, 2)
        guard case .user(let first) = held.items[0], case .user(let second) = held.items[1] else {
            return XCTFail("unexpected item kinds")
        }
        XCTAssertEqual(first.text, "first")
        XCTAssertEqual(second.text, "second")
        XCTAssertEqual(held.oldestSeq, 4)
        XCTAssertFalse(held.hasMore)
    }

    /// After a prepend the index maps have to be rebuilt, or a live chunk for a
    /// bubble already on screen appends a second one.
    func testPrependKeepsLiveStreamingCoherent() {
        let held = conversation()
        held.apply(event: event("assistant/chunk", seq: 20, data: .object([
            "turn": 2, "step": 0,
            "chunk": .object(["type": .string("text-delta"), "text": .string("live")]),
        ])), view: nil)
        held.absorb(page: .object([
            "events": .array([
                .object(["event": event("user/message", seq: 1, data: .object([
                    "id": .string("m1"), "content": text("older"), "source": .object(["kind": .string("user")]),
                ]))]),
            ]),
            "hasMore": .bool(false),
        ]), prepend: true)
        held.apply(event: event("assistant/chunk", seq: 21, data: .object([
            "turn": 2, "step": 0,
            "chunk": .object(["type": .string("text-delta"), "text": .string(" more")]),
        ])), view: nil)

        XCTAssertEqual(held.items.count, 2)
        guard case .assistant(let bubble) = held.items[1] else { return XCTFail("expected a bubble") }
        XCTAssertEqual(bubble.text, "live more")
    }

    // MARK: - Projections

    /// Projection frames can overtake the history baseline on a reconnect. A stale
    /// one must not undo a newer value.
    func testStaleProjectionIsDropped() {
        let held = conversation()
        held.applyProjection(key: "title", value: .string("New title"), seq: 40)
        held.applyProjection(key: "title", value: .string("Old title"), seq: 12)
        XCTAssertEqual(held.title, "New title")
    }

    func testTodosAndContextProjections() {
        let held = conversation()
        held.absorbProjections(.object([
            "asOfSeq": 30,
            "values": .object([
                "todos": .array([
                    .object(["content": .string("Read the code"), "status": .string("completed")]),
                    .object(["content": .string("Write the fix"), "status": .string("in_progress")]),
                ]),
                "contextPressure": .object(["contextWindow": 200_000, "projectedTokens": 50_000]),
                "plan": .object(["mode": .string("plan")]),
            ]),
        ]))
        XCTAssertEqual(held.todos.count, 2)
        XCTAssertEqual(held.todos[1].status, .inProgress)
        XCTAssertEqual(held.contextFraction ?? 0, 0.25, accuracy: 0.0001)
        XCTAssertTrue(held.planning)
    }

    // MARK: - Optimistic sends

    func testPendingMessageAppearsAndCanBeDropped() {
        let held = conversation()
        held.showPending(text: "sending", id: "p1")
        XCTAssertEqual(held.items.count, 1)
        held.dropPending(id: "p1")
        XCTAssertTrue(held.items.isEmpty)
    }

    func testQueueSnapshotReplaces() {
        let held = conversation()
        held.applyQueue([
            .object(["id": .string("q1"), "message": .object(["content": text("later")]), "placement": .string("queued")]),
        ])
        XCTAssertEqual(held.queue.map(\.text), ["later"])
        held.applyQueue([])
        XCTAssertTrue(held.queue.isEmpty)
    }
}

// MARK: - Presentation parsing

@MainActor
final class PresentationTests: XCTestCase {
    func testSearchResultFlattensFileMatches() {
        let view: JSONValue = .object([
            "card": .string("search"),
            "title": .string("grep todo"),
            "files": .array([
                .object([
                    "path": .string("a.swift"),
                    "matches": .array([.object(["lineNumber": 12, "line": .string("// todo")])]),
                ]),
            ]),
            "total": 1,
        ])
        let presentation = Conversation.resultPresentation(view, current: .generic(title: "grep", kind: nil, detail: nil))
        guard case .search(let title, let lines, _, let total) = presentation else { return XCTFail("expected search") }
        XCTAssertEqual(title, "grep todo")
        XCTAssertEqual(lines, ["a.swift:12  // todo"])
        XCTAssertEqual(total, 1)
    }

    func testPathShapedSearch() {
        let view: JSONValue = .object([
            "card": .string("search"),
            "shape": .string("paths"),
            "paths": .array([.string("a.swift"), .string("b.swift")]),
            "truncated": .bool(true),
            "total": 40,
        ])
        let presentation = Conversation.resultPresentation(view, current: .generic(title: "find", kind: nil, detail: nil))
        guard case .search(_, let lines, let truncated, let total) = presentation else { return XCTFail("expected search") }
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(truncated)
        XCTAssertEqual(total, 40)
    }

    func testReadCardKeepsFileNumbering() {
        let view: JSONValue = .object([
            "card": .string("read"),
            "path": .string("/tmp/a.swift"),
            "lines": .array([
                .object(["number": 40, "text": .string("let x = 1")]),
                .object(["number": 41, "text": .string("")]),
            ]),
            "totalLines": 120,
        ])
        let presentation = Conversation.resultPresentation(view, current: .generic(title: "read", kind: nil, detail: nil))
        guard case .read(let path, let lines, let total) = presentation else { return XCTFail("expected read") }
        XCTAssertEqual(path, "/tmp/a.swift")
        XCTAssertEqual(lines.first?.number, 40)
        XCTAssertEqual(total, 120)
    }

    func testDiffCardCarriesBothSides() {
        let view: JSONValue = .object([
            "card": .string("diff"),
            "title": .string("edit a.swift"),
            "diffs": .array([
                .object([
                    "path": .string("/tmp/a.swift"),
                    "oldText": .string("one\ntwo"),
                    "newText": .string("one\nthree"),
                ]),
            ]),
        ])
        let presentation = Conversation.callPresentation(view, for: "call", name: "edit", arguments: "{}")
        guard case .diff(let title, let files) = presentation else { return XCTFail("expected diff") }
        XCTAssertEqual(title, "edit a.swift")
        XCTAssertEqual(files.first?.oldText, "one\ntwo")
    }

    /// A tool with no render intent still needs a card, named after itself.
    func testUnknownToolFallsBackToGeneric() {
        let presentation = Conversation.callPresentation(nil, for: nil, name: "plugin.thing", arguments: "{}")
        guard case .generic(let title, _, _) = presentation else { return XCTFail("expected generic") }
        XCTAssertEqual(title, "plugin.thing")
    }
}

// MARK: - Session summaries

final class SessionSummaryTests: XCTestCase {
    func testParsesListRow() {
        let summary = SessionSummary(.object([
            "sessionId": .string("s1"),
            "updatedAt": .number(1_700_000_000_000),
            "running": .bool(true),
            "blank": .bool(false),
            "cwd": .string("/Users/x/code/thing"),
            "origin": .string("user"),
            "projections": .object(["values": .object(["title": .string("Fix the parser")])]),
        ]))
        XCTAssertEqual(summary?.id, "s1")
        XCTAssertEqual(summary?.displayTitle, "Fix the parser")
        XCTAssertEqual(summary?.running, true)
        XCTAssertEqual(summary?.isSubagent, false)
    }

    func testUntitledSessionFallsBackToFolder() {
        let summary = SessionSummary(.object([
            "sessionId": .string("s2"),
            "cwd": .string("/Users/x/code/thing"),
        ]))
        XCTAssertEqual(summary?.displayTitle, "thing")
    }

    func testBlankSessionSaysSo() {
        let summary = SessionSummary(.object([
            "sessionId": .string("s3"),
            "blank": .bool(true),
        ]))
        XCTAssertEqual(summary?.displayTitle, "New conversation")
    }

    func testSubagentIsFlagged() {
        let summary = SessionSummary(.object([
            "sessionId": .string("s4"),
            "origin": .string("subagent"),
        ]))
        XCTAssertEqual(summary?.isSubagent, true)
    }

    func testRowWithoutIdIsRejected() {
        XCTAssertNil(SessionSummary(.object(["cwd": .string("/tmp")])))
    }
}

// MARK: - Optimistic sends against the real echo

@MainActor
final class OptimisticSendTests: XCTestCase {
    private func event(_ type: String, seq: Int, data: JSONValue) -> JSONValue {
        .object(["type": .string(type), "seq": .number(Double(seq)), "time": .number(1_700_000_000_000), "data": data])
    }

    private func userMessage(_ text: String, id: String, seq: Int) -> JSONValue {
        event("user/message", seq: seq, data: .object([
            "id": .string(id),
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "source": .object(["kind": .string("user")]),
        ]))
    }

    /// The bug this exists for: the harness mints its own id, so the echoed
    /// message could never match the optimistic bubble, and every single message
    /// a person sent appeared on screen twice.
    func testTheRealMessageReplacesTheOptimisticOne() {
        let held = Conversation(sessionId: "s1")
        held.showPending(text: "what model are you", id: "pending-1")
        XCTAssertEqual(held.items.count, 1)

        held.apply(event: userMessage("what model are you", id: "m-abc", seq: 5), view: nil)

        XCTAssertEqual(held.items.count, 1, "the message must appear once, not twice")
        guard case .user(let user) = held.items[0] else { return XCTFail("expected a user turn") }
        XCTAssertEqual(user.id, "m-abc", "the surviving copy is the real one, so later events can address it")
    }

    /// Two sends of the same text must consume one bubble each, not both at once.
    func testRepeatedTextClearsOneBubblePerEcho() {
        let held = Conversation(sessionId: "s1")
        held.showPending(text: "again", id: "pending-1")
        held.showPending(text: "again", id: "pending-2")
        XCTAssertEqual(held.items.count, 2)

        held.apply(event: userMessage("again", id: "m-1", seq: 5), view: nil)
        XCTAssertEqual(held.items.count, 2, "one optimistic bubble is consumed, one still outstanding")

        held.apply(event: userMessage("again", id: "m-2", seq: 6), view: nil)
        XCTAssertEqual(held.items.count, 2)
        XCTAssertEqual(held.items.map(\.id), ["m-1", "m-2"], "both real copies, no optimistic leftovers")
    }

    /// Whitespace the person typed must not stop the match.
    func testMatchingIgnoresSurroundingWhitespace() {
        let held = Conversation(sessionId: "s1")
        held.showPending(text: "  hello  ", id: "pending-1")
        held.apply(event: userMessage("hello", id: "m-1", seq: 5), view: nil)
        XCTAssertEqual(held.items.count, 1)
    }

    /// A message from somewhere else — the web UI, another phone — must not eat
    /// an outstanding optimistic bubble that happens to read the same.
    func testAnUnrelatedMessageStillAppends() {
        let held = Conversation(sessionId: "s1")
        held.showPending(text: "mine", id: "pending-1")
        held.apply(event: userMessage("someone else's", id: "m-1", seq: 5), view: nil)
        XCTAssertEqual(held.items.count, 2, "no match means nothing is removed")
    }

    /// A failed send drops its bubble and leaves nothing behind to match later.
    func testAFailedSendLeavesNoGhost() {
        let held = Conversation(sessionId: "s1")
        held.showPending(text: "lost", id: "pending-1")
        held.dropPending(id: "pending-1")
        XCTAssertTrue(held.items.isEmpty)

        held.apply(event: userMessage("lost", id: "m-1", seq: 5), view: nil)
        XCTAssertEqual(held.items.count, 1, "a later real message is unaffected by the dropped bubble")
    }
}
