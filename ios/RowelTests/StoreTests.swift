/// The fold, and the parsing around it.
///
/// `Conversation` turns the harness's append-only event log into what the screen
/// shows. It is the piece most likely to be wrong in a way nobody notices — a
/// duplicated message, a bubble that never stops streaming, a tool card that
/// loses its result — so these tests drive it with the same event shapes the
/// machine actually sends, down to recordings of a real dsh 0.2
/// (`Fixtures/dsh-0.2`, made by `e2e/scripts/capture-fixtures.mjs`).

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

    private func start(turn: Int, step: Int, attempt: String = "s1:1") -> JSONValue {
        .object([
            "type": .string("start"), "attemptId": .string(attempt),
            "turn": .number(Double(turn)), "step": .number(Double(step)), "revision": 1, "startedAfterSeq": 0,
        ])
    }

    private func chunk(_ kind: String, _ value: String, attempt: String = "s1:1") -> JSONValue {
        .object([
            "type": .string("chunk"), "attemptId": .string(attempt), "index": 0, "time": 1_700_000_000_000,
            "chunk": .object(["type": .string(kind), "index": 0, "text": .string(value)]),
        ])
    }

    private func end(_ outcome: String, attempt: String = "s1:1") -> JSONValue {
        .object(["type": .string("end"), "attemptId": .string(attempt), "outcome": .object(["kind": .string(outcome)])])
    }

    // MARK: - Messages

    /// A queued message that the machine has spoken must leave the strip, even
    /// if the `inbox` update that says so was missed across a reconnect.
    func testAClaimedMessageLeavesTheQueueStrip() {
        let held = conversation()
        held.showQueued(text: "能搜索个美股信息看看不", id: "req-1")
        XCTAssertEqual(held.queue.count, 1)

        held.apply(event: event("user/message", seq: 5, data: .object([
            "id": .string("m5"),
            "content": text("能搜索个美股信息看看不"),
            "source": .object(["kind": .string("user"), "rpcId": .string("req-1")]),
        ])))

        XCTAssertEqual(held.queue.count, 0, "the transcript says it was heard; the strip may not keep offering it")
        XCTAssertEqual(held.items.count, 1)
    }

    /// The `inbox` projection lists what is waiting; this device's provisional
    /// entry gives way to the machine's own once the machine names its request.
    func testTheInboxReplacesTheProvisionalEntry() {
        let held = conversation()
        held.showQueued(text: "later", id: "req-1")
        held.showQueued(text: "not yet listed", id: "req-2")
        held.applyProjection(key: "inbox", value: .object([
            "next-turn": .array([.object([
                "id": .string("inbox-1"), "role": .string("user"), "content": text("later"),
                "source": .object(["kind": .string("user"), "rpcId": .string("req-1")]),
            ])]),
            "next-step": .array([.object([
                "id": .string("inbox-2"), "role": .string("user"), "content": text("from the Mac"),
                "source": .object(["kind": .string("user"), "rpcId": .string("web-1")]),
            ])]),
        ]), seq: 3)
        XCTAssertEqual(held.queue.map(\.id), ["inbox-2", "inbox-1", "req-2"])
        XCTAssertEqual(held.queue.map(\.placement), ["steering", "queued", "queued"])

        held.applyProjection(key: "inbox", value: .object(["next-turn": .array([]), "next-step": .array([])]), seq: 4)
        XCTAssertEqual(held.queue.map(\.id), ["req-2"], "still on its way; nothing has said where it went")
    }

    func testUserAndAssistantMessagesRender() {
        let held = conversation()
        held.apply(event: event("user/message", seq: 1, data: .object([
            "id": .string("m1"),
            "content": text("hello"),
            "source": .object(["kind": .string("user")]),
        ])))
        held.apply(event: event("assistant/message", seq: 2, data: .object([
            "turn": 1, "step": 0,
            "message": .object(["content": text("hi back")]),
        ])))

        XCTAssertEqual(held.items.count, 2)
        guard case .user(let user) = held.items[0], case .assistant(let assistant) = held.items[1] else {
            return XCTFail("unexpected item kinds")
        }
        XCTAssertEqual(user.text, "hello")
        XCTAssertFalse(user.synthetic)
        XCTAssertEqual(assistant.text, "hi back")
        XCTAssertTrue(assistant.complete)
    }

    /// Streamed chunks build a bubble; the final message replaces it rather
    /// than appending a second copy, and the `end` after it changes nothing.
    func testChunksBuildOneBubbleThenFinalise() {
        let held = conversation()
        held.receiveStream(start(turn: 1, step: 0))
        for piece in ["Let", " me", " think"] {
            held.receiveStream(chunk("text-delta", piece))
        }
        XCTAssertEqual(held.items.count, 1)
        guard case .assistant(let streaming) = held.items[0] else { return XCTFail("expected a bubble") }
        XCTAssertEqual(streaming.text, "Let me think")
        XCTAssertFalse(streaming.complete)

        held.apply(event: event("assistant/message", seq: 4, data: .object([
            "turn": 1, "step": 0,
            "message": .object(["content": text("Let me think about it.")]),
        ])))
        held.receiveStream(end("committed"))
        XCTAssertEqual(held.items.count, 1)
        guard case .assistant(let finished) = held.items[0] else { return XCTFail("expected a bubble") }
        XCTAssertEqual(finished.text, "Let me think about it.")
        XCTAssertTrue(finished.complete)
    }

    /// An abandoned attempt leaves nothing in the log, so nothing it streamed
    /// may stay on screen.
    func testAnAbandonedAttemptIsTakenDown() {
        let held = conversation()
        held.receiveStream(start(turn: 1, step: 1))
        held.receiveStream(chunk("text-delta", "half a th"))
        held.receiveStream(end("abandoned"))
        XCTAssertTrue(held.items.isEmpty)
    }

    /// A failed attempt is logged as `assistant/attempt`; a retry streams into
    /// the same step and must not be appended to the failed text.
    func testARetriedAttemptStartsAFreshBubble() {
        let held = conversation()
        held.receiveStream(start(turn: 1, step: 1, attempt: "s1:1"))
        held.receiveStream(chunk("text-delta", "first try", attempt: "s1:1"))
        held.apply(event: event("assistant/attempt", seq: 7, data: .object(["turn": 1, "step": 1])))
        held.receiveStream(end("committed", attempt: "s1:1"))
        held.receiveStream(start(turn: 1, step: 1, attempt: "s1:2"))
        held.receiveStream(chunk("text-delta", "second", attempt: "s1:2"))
        guard case .assistant(let bubble) = held.items.first, held.items.count == 1 else { return XCTFail("expected one bubble") }
        XCTAssertEqual(bubble.text, "second")
    }

    /// Chunks of an attempt this conversation never saw start belong to no
    /// bubble it can name.
    func testChunksWithoutTheirStartAreIgnored() {
        let held = conversation()
        held.receiveStream(chunk("text-delta", "stray"))
        XCTAssertTrue(held.items.isEmpty)
    }

    /// The same event arriving twice — an older page that overlaps the window —
    /// must not render twice.
    func testDuplicateSequenceIsIgnored() {
        let held = conversation()
        let message = event("user/message", seq: 9, data: .object([
            "id": .string("m1"),
            "content": text("once"),
            "source": .object(["kind": .string("user")]),
        ]))
        held.apply(event: message)
        held.apply(event: message)
        XCTAssertEqual(held.items.count, 1)
    }

    /// A step that only called tools produces an empty assistant message. Leaving
    /// the bubble would put a gap above the tool cards.
    func testEmptyAssistantStepLeavesNoBubble() {
        let held = conversation()
        held.receiveStream(start(turn: 1, step: 0))
        held.receiveStream(chunk("reasoning-delta", "hmm"))
        held.apply(event: event("assistant/message", seq: 2, data: .object([
            "turn": 1, "step": 0,
            "message": .object(["content": .array([])]),
        ])))
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
        ])))
        guard case .user(let user) = held.items.first else { return XCTFail("expected an item") }
        XCTAssertTrue(user.synthetic)
        XCTAssertEqual(user.text, "AGENTS.md")
    }

    /// dsh 0.2 restates where it is running before every turn. It is the
    /// machine talking to the model, and on screen it was a page of boilerplate.
    func testRuntimeContextIsNotShown() {
        let held = conversation()
        held.apply(event: event("user/message", seq: 1, data: .object([
            "id": .string("m1"),
            "content": text("Current runtime context. This snapshot supersedes earlier runtime-context snapshots."),
            "source": .object(["kind": .string("runtime-context"), "form": .string("snapshot")]),
        ])))
        XCTAssertTrue(held.items.isEmpty)
    }

    /// A tool result reaches the log as `tool/result`. One arriving as a user
    /// message is a duplicate of a card already on screen.
    func testToolSourcedUserMessageIsDropped() {
        let held = conversation()
        held.apply(event: event("user/message", seq: 1, data: .object([
            "content": text("tool output"),
            "source": .object(["kind": .string("tool")]),
        ])))
        XCTAssertTrue(held.items.isEmpty)
    }

    // MARK: - Tools

    /// The shapes from docs/dsh-0.2-protocol.md §8.2: the result's text is the
    /// message's own content, and its call is named on the message.
    func testToolCallAndResultShareOneCard() {
        let held = conversation()
        held.apply(event: event("tool/call", seq: 1, data: .object([
            "turn": 1, "step": 1,
            "callId": .string("c1"),
            "name": .string("bash"),
            "arguments": .string(#"{"command":"ls","description":"List files","workdir":"/tmp"}"#),
        ])))

        guard case .tool(let pending) = held.items.first else { return XCTFail("expected a card") }
        XCTAssertTrue(pending.running)
        XCTAssertEqual(pending.headline, "ls")

        held.apply(event: event("tool/result", seq: 2, data: .object([
            "turn": 1, "step": 1,
            "message": .object([
                "role": .string("tool"),
                "source": .object(["kind": .string("tool"), "callId": .string("c1")]),
                "toolCallId": .string("c1"),
                "content": text("a.txt\n[exit code: 0]"),
                "isError": .bool(false),
            ]),
        ])))

        XCTAssertEqual(held.items.count, 1)
        guard case .tool(let done) = held.items[0] else { return XCTFail("expected a card") }
        XCTAssertFalse(done.running)
        XCTAssertFalse(done.failed)
        XCTAssertEqual(done.headline, "ls")
        guard case .terminal(_, let cwd, _, let exit) = done.presentation else { return XCTFail("expected terminal") }
        XCTAssertEqual(cwd, "/tmp")
        XCTAssertEqual(exit, 0)
        XCTAssertEqual(done.resultText, "a.txt\n[exit code: 0]")
    }

    func testAnsweredQuestionKeepsTheChoiceInTheTranscript() {
        // The shape dsh logs for `ask_user_question`: questions in the call's
        // arguments, the person's answer as JSON text in the result — so it
        // fell through to a generic card that showed `{"answers":[…]}` instead
        // of what was asked and what was picked.
        let held = conversation()
        let arguments = #"{"questions":[{"id":"quota_scope","header":"Scope","question":"Which quota?","options":[{"label":"Session context","description":"Tokens left in this session."},{"label":"Provider balance"}]}]}"#
        held.apply(event: event("tool/call", seq: 1, data: .object([
            "callId": .string("q1"),
            "name": .string("ask_user_question"),
            "arguments": .string(arguments),
        ])))

        guard case .tool(let asked) = held.items.first,
              case .question(let items, let pending) = asked.presentation
        else { return XCTFail("expected a question card") }
        XCTAssertEqual(items.map(\.question), ["Which quota?"])
        XCTAssertEqual(items.first?.options.map(\.label), ["Session context", "Provider balance"])
        XCTAssertNil(pending, "nothing is answered until the result lands")
        XCTAssertEqual(asked.headline, "Scope")

        held.apply(event: event("tool/result", seq: 2, data: .object([
            "message": .object([
                "source": .object(["kind": .string("tool"), "callId": .string("q1")]),
                "toolCallId": .string("q1"),
                "content": text(#"{"answers":[{"id":"quota_scope","selected":["Session context"],"custom":"and the weekly cap"}]}"#),
            ]),
        ])))

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
        ])))
        guard case .tool(let card) = held.items.first else { return XCTFail("expected a card") }
        guard case .generic = card.presentation else { return XCTFail("unreadable arguments keep the generic card") }
    }

    func testQuestionWithOneUnreadableItemStaysGeneric() {
        let held = conversation()
        held.apply(event: event("tool/call", seq: 1, data: .object([
            "callId": .string("q3"),
            "name": .string("ask_user_question"),
            "arguments": .string(#"{"questions":[{"id":"a","question":"Which?","options":[{"label":"One"}]},{"id":"b"}]}"#),
        ])))
        guard case .tool(let card) = held.items.first else { return XCTFail("expected a card") }
        guard case .generic = card.presentation else {
            return XCTFail("a card that drops one of the questions must not stand in for the call")
        }
    }

    /// Recorded live (docs/dsh-0.2-protocol.md §8.2): a read of a missing file.
    func testFailedToolIsMarked() {
        let held = conversation()
        held.apply(event: event("tool/call", seq: 48, data: .object([
            "turn": 3, "step": 2,
            "callId": .string("call_00_oi48"), "name": .string("read"),
            "arguments": .string(#"{"file_path":"/tmp/dshref/ws/nonexistent.txt"}"#),
        ])))
        held.apply(event: event("tool/result", seq: 49, data: .object([
            "turn": 3, "step": 2,
            "message": .object([
                "role": .string("tool"),
                "source": .object(["kind": .string("tool"), "callId": .string("call_00_oi48")]),
                "toolCallId": .string("call_00_oi48"),
                "content": text(#"Error: cannot read "/tmp/dshref/ws/nonexistent.txt": not found"#),
                "isError": .bool(true),
                "id": .string("2258"),
            ]),
            "error": .object(["name": .string("FsError"), "code": .string("FS_NOT_FOUND")]),
        ])))
        guard case .tool(let card) = held.items[0] else { return XCTFail("expected a card") }
        XCTAssertTrue(card.failed)
        XCTAssertEqual(card.headline, "/tmp/dshref/ws/nonexistent.txt")
        XCTAssertEqual(card.resultText, #"Error: cannot read "/tmp/dshref/ws/nonexistent.txt": not found"#)
    }

    /// A result whose call was never seen — the call is on an older page —
    /// must be dropped rather than creating a card with no context.
    func testOrphanResultIsIgnored() {
        let held = conversation()
        held.apply(event: event("tool/result", seq: 1, data: .object([
            "message": .object(["toolCallId": .string("ghost"), "content": text("?")]),
        ])))
        XCTAssertTrue(held.items.isEmpty)
    }

    // MARK: - Turn boundaries

    /// A turn can end without a final message — cancelled, or a provider error.
    /// A bubble left streaming would claim the answer is still coming.
    func testTurnEndCompletesStreamingBubbles() {
        let held = conversation()
        held.apply(event: event("turn/start", seq: 1))
        held.receiveStream(start(turn: 1, step: 0))
        held.receiveStream(chunk("text-delta", "part"))
        held.apply(event: event("tool/call", seq: 3, data: .object([
            "callId": .string("c1"), "name": .string("bash"),
        ])))
        XCTAssertTrue(held.running)

        held.apply(event: event("turn/end", seq: 4, data: .object([
            "reason": .object(["kind": .string("error"), "error": .object(["message": .string("no API key for provider route")])]),
        ])))

        XCTAssertFalse(held.running)
        guard case .assistant(let bubble) = held.items[0], case .tool(let card) = held.items[1] else {
            return XCTFail("unexpected item kinds")
        }
        XCTAssertTrue(bubble.complete)
        XCTAssertFalse(card.running)
        guard case .notice(let notice) = held.items[2] else { return XCTFail("expected a notice") }
        XCTAssertEqual(notice.text, "no API key for provider route")
        XCTAssertEqual(notice.kind, .failure)
    }

    func testSuccessfulTurnEndAddsNoNotice() {
        let held = conversation()
        held.apply(event: event("turn/end", seq: 1, data: .object([
            "reason": .object(["kind": .string("completed")]),
        ])))
        XCTAssertTrue(held.items.isEmpty)
    }

    /// An event type this build has never heard of must render nothing, not a
    /// placeholder. Plugins add event types and a client that guessed would draw
    /// noise into every transcript.
    func testUnknownEventIsSilent() {
        let held = conversation()
        held.apply(event: event("plugin/something-new", seq: 1, data: .object(["x": 1])))
        XCTAssertTrue(held.items.isEmpty)
    }

    // MARK: - Snapshots and pages

    private func record(_ event: JSONValue) -> JSONValue {
        .object(["type": .string("event"), "event": event])
    }

    func testOlderPagePrependsInOrder() {
        let held = conversation()
        held.adopt(snapshot: snapshot([
            event("user/message", seq: 10, data: .object([
                "id": .string("m10"), "content": text("second"), "source": .object(["kind": .string("user")]),
            ])),
        ], hasMore: true))
        XCTAssertEqual(held.oldestSeq, 10)
        XCTAssertEqual(held.cursor, 10)
        XCTAssertTrue(held.hasMore)
        XCTAssertTrue(held.loaded)

        held.absorb(page: .object([
            "records": .array([
                record(event("user/message", seq: 4, data: .object([
                    "id": .string("m4"), "content": text("first"), "source": .object(["kind": .string("user")]),
                ]))),
            ]),
            "hasMore": .bool(false),
        ]))

        XCTAssertEqual(held.items.count, 2)
        guard case .user(let first) = held.items[0], case .user(let second) = held.items[1] else {
            return XCTFail("unexpected item kinds")
        }
        XCTAssertEqual(first.text, "first")
        XCTAssertEqual(second.text, "second")
        XCTAssertEqual(held.oldestSeq, 4)
        XCTAssertEqual(held.cursor, 10, "an older page does not move the window's end")
        XCTAssertFalse(held.hasMore)
    }

    /// After a prepend the index maps have to be rebuilt, or a live chunk for a
    /// bubble already on screen appends a second one.
    func testPrependKeepsLiveStreamingCoherent() {
        let held = conversation()
        held.receiveStream(start(turn: 2, step: 0))
        held.receiveStream(chunk("text-delta", "live"))
        held.absorb(page: .object([
            "records": .array([
                record(event("user/message", seq: 1, data: .object([
                    "id": .string("m1"), "content": text("older"), "source": .object(["kind": .string("user")]),
                ]))),
            ]),
            "hasMore": .bool(false),
        ]))
        held.receiveStream(chunk("text-delta", " more"))

        XCTAssertEqual(held.items.count, 2)
        guard case .assistant(let bubble) = held.items[1] else { return XCTFail("expected a bubble") }
        XCTAssertEqual(bubble.text, "live more")
    }

    /// A reconnect brings a new snapshot, and it replaces the window outright:
    /// nothing from before survives except what this device is still sending.
    func testASnapshotReplacesTheWindow() {
        let held = conversation()
        held.adopt(snapshot: snapshot([
            event("user/message", seq: 3, data: .object(["id": .string("m3"), "content": text("old"), "source": .object(["kind": .string("user")])])),
        ]))
        held.showPending(text: "on its way", id: "req-9")
        let before = held.generation

        held.adopt(snapshot: snapshot([
            event("user/message", seq: 7, data: .object(["id": .string("m7"), "content": text("newer"), "source": .object(["kind": .string("user")])])),
        ]))

        XCTAssertEqual(held.items.map(\.id), ["m7", "req-9"])
        XCTAssertGreaterThan(held.generation, before, "a page asked for against the old window must not land")

        held.apply(event: event("user/message", seq: 8, data: .object([
            "id": .string("m8"), "content": text("on its way"),
            "source": .object(["kind": .string("user"), "rpcId": .string("req-9")]),
        ])))
        XCTAssertEqual(held.items.map(\.id), ["m7", "m8"])
    }

    /// Opened mid-answer: the snapshot carries what the model has streamed so
    /// far, in the log's compact form, and the frames after it continue it.
    func testASnapshotResumesTheAttemptInFlight() {
        let held = conversation()
        var opened = snapshot([event("turn/start", seq: 46, data: .object(["turn": 2]))])
        if case .object(var fields) = opened {
            fields["assistantStream"] = .object([
                "revision": 171,
                "activeAttempt": .object([
                    "attemptId": .string("s1:5"), "startedAfterSeq": 46, "turn": 2, "step": 1, "nextIndex": 3,
                    "stream": .array([
                        .object(["type": .string("chunk"), "time": 1, "chunk": .object(["type": .string("block-start"), "index": 0, "blockType": .string("reasoning")])]),
                        .object(["type": .string("reasoning-chunks"), "time0": 1, "index": 0, "dt": .array([1, 0]), "texts": .array([.string("The"), .string(" user")])]),
                        .object(["type": .string("text-chunks"), "time0": 2, "index": 1, "dt": .array([1]), "texts": .array([.string("Hello")])]),
                    ]),
                ]),
            ])
            opened = .object(fields)
        }
        held.adopt(snapshot: opened)
        held.receiveStream(chunk("text-delta", " there", attempt: "s1:5"))

        guard case .assistant(let bubble) = held.items.first else { return XCTFail("expected the bubble in flight") }
        XCTAssertEqual(bubble.reasoning, "The user")
        XCTAssertEqual(bubble.text, "Hello there")
        XCTAssertFalse(bubble.complete)
        XCTAssertTrue(held.running)
    }

    /// The recording of a real dsh 0.2 turn: a prompt with a photo that ended
    /// for want of a model.
    func testARecordedFollowFoldsIntoWhatTheWebUIShows() throws {
        let recording = try fixture("session-follow-live")
        let items = recording["items"]?.arrayValue ?? []
        let held = Conversation(sessionId: recording.path("args", "request", "address", "sessionId")?.stringValue ?? "")
        for item in items {
            switch item["type"]?.stringValue {
            case "snapshot": held.adopt(snapshot: item)
            case "event": held.apply(event: item["event"] ?? .null)
            case "assistant-stream": held.receiveStream(item["frame"] ?? .null)
            default: XCTFail("unexpected follow item \(item["type"]?.stringValue ?? "?")")
            }
        }
        XCTAssertTrue(held.loaded)
        XCTAssertFalse(held.running)
        XCTAssertEqual(held.title, "Hello from the fixture")
        guard held.items.count == 2, case .user(let prompt) = held.items[0], case .notice(let failure) = held.items[1] else {
            return XCTFail("expected the prompt and the failure, got \(held.items.map(\.id))")
        }
        XCTAssertEqual(prompt.text, "Hello from the fixture")
        XCTAssertEqual(prompt.images.count, 1, "the photo is shown by reference")
        XCTAssertFalse(prompt.synthetic)
        XCTAssertTrue(failure.text.contains("no API key"), failure.text)
    }

    /// The same conversation through `session/page`: the same transcript.
    func testARecordedPageFoldsLikeTheSnapshot() throws {
        let page = try fixture("session-page")
        let held = conversation()
        held.absorb(page: page["result"]?["value"] ?? .null)
        XCTAssertEqual(held.items.count, 2)
        XCTAssertFalse(held.hasMore)
    }

    // MARK: - Projections

    /// Projection frames can overtake the snapshot on a reconnect. A stale one
    /// must not undo a newer value.
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
                "plan": .object(["active": .bool(true), "pending": .bool(false)]),
            ]),
        ]))
        XCTAssertEqual(held.todos.count, 2)
        XCTAssertEqual(held.todos[1].status, .inProgress)
        XCTAssertEqual(held.contextFraction ?? 0, 0.25, accuracy: 0.0001)
        XCTAssertTrue(held.planning)
    }

    /// `session/control` and `session/follow` are separate streams. A value the
    /// first delivered after the snapshot was taken must survive the snapshot.
    func testASnapshotDoesNotPutBackAnOlderProjection() {
        let held = conversation()
        held.applyProjection(key: "title", value: .string("Newer"), seq: 20)
        held.adopt(snapshot: snapshot([event("turn/start", seq: 19)], projections: .object(["title": .string("Older")])))
        XCTAssertEqual(held.title, "Newer")
    }

    /// The `session/control` baseline a real dsh sent, applied as a block.
    func testARecordedProjectionBaselineApplies() throws {
        let control = try fixture("session-control")
        let projections = control["items"]?.arrayValue?.first?.path("value", "projections")?.objectValue ?? [:]
        guard let (sessionId, block) = projections.first else { return XCTFail("the baseline names no session") }
        let held = Conversation(sessionId: sessionId)
        held.absorbProjections(block)
        XCTAssertEqual(held.title, "Hello from the fixture")
        XCTAssertEqual(held.permissions?.current, block.path("values", "permissions", "currentValue")?.stringValue)
        XCTAssertNotNil(held.permissions)
        XCTAssertEqual(held.stats?.turns, 1)
        XCTAssertTrue(held.queue.isEmpty)
    }

    /// dsh 0.2's `permissions` projection names only the current preset; the
    /// choices come from the machine's catalog, whichever arrives first.
    func testAccessChoicesComeFromTheCatalog() {
        let presets = ["read-only", "workspace-write"].map { PermissionChoice.Option(value: $0, name: $0) }
        let early = conversation()
        early.applyProjection(key: "permissions", value: .object(["currentValue": .string("read-only")]), seq: 2)
        XCTAssertEqual(early.permissions?.choices.count, 0)
        early.offer(presets: presets)
        XCTAssertEqual(early.permissions?.choices.map(\.value), ["read-only", "workspace-write"])

        let late = conversation()
        late.offer(presets: presets)
        late.applyProjection(key: "permissions", value: .object(["currentValue": .string("workspace-write")]), seq: 2)
        XCTAssertEqual(late.permissions?.current, "workspace-write")
        XCTAssertEqual(late.permissions?.choices.count, 2)
    }

    // MARK: - Optimistic sends

    func testPendingMessageAppearsAndCanBeDropped() {
        let held = conversation()
        held.showPending(text: "sending", id: "p1")
        XCTAssertEqual(held.items.count, 1)
        held.dropPending(id: "p1")
        XCTAssertTrue(held.items.isEmpty)
    }
}

// MARK: - Presentation parsing

/// dsh 0.2 sends no render hints, so the card is chosen from the tool's name
/// and arguments (the schemas a real dsh offers, from `request/header`).
@MainActor
final class PresentationTests: XCTestCase {
    func testEditIsADiffOfItsTwoStrings() {
        let presentation = Conversation.callPresentation(
            name: "edit",
            arguments: #"{"file_path":"/tmp/a.swift","old_string":"one\ntwo","new_string":"one\nthree"}"#
        )
        guard case .diff(let title, let files) = presentation else { return XCTFail("expected diff") }
        XCTAssertEqual(title, "/tmp/a.swift")
        XCTAssertEqual(files.first?.oldText, "one\ntwo")
        XCTAssertEqual(files.first?.newText, "one\nthree")
    }

    func testWriteIsADiffWithNothingBefore() {
        let presentation = Conversation.callPresentation(name: "write", arguments: ##"{"file_path":"/tmp/b.md","content":"# Hi"}"##)
        guard case .diff(_, let files) = presentation else { return XCTFail("expected diff") }
        XCTAssertNil(files.first?.oldText)
        XCTAssertEqual(files.first?.newText, "# Hi")
    }

    func testSearchResultIsItsLines() {
        let call = Conversation.callPresentation(name: "grep", arguments: #"{"pattern":"todo","path":"/tmp"}"#)
        let presentation = Conversation.resultPresentation("a.swift:12: // todo\nb.swift:3: todo\n", current: call)
        guard case .search(let title, let lines, _, let total) = presentation else { return XCTFail("expected search") }
        XCTAssertEqual(title, "todo")
        XCTAssertEqual(lines, ["a.swift:12: // todo", "b.swift:3: todo"])
        XCTAssertEqual(total, 2)
    }

    func testTheShellsExitCodeIsRead() {
        XCTAssertEqual(Conversation.exitCode(in: "boom\n[exit code: 2]"), 2)
        XCTAssertNil(Conversation.exitCode(in: "no marker"))
    }

    /// A tool this build has never heard of still needs a card, named after
    /// itself, with whatever argument says most about it.
    func testUnknownToolFallsBackToGeneric() {
        let presentation = Conversation.callPresentation(name: "plugin.thing", arguments: #"{"path":"/tmp/x"}"#)
        guard case .generic(let title, _, let detail) = presentation else { return XCTFail("expected generic") }
        XCTAssertEqual(title, "plugin.thing")
        XCTAssertEqual(detail, "/tmp/x")
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

    private func userMessage(_ text: String, id: String, seq: Int, requestId: String? = nil) -> JSONValue {
        event("user/message", seq: seq, data: .object([
            "id": .string(id),
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "source": .object(dropping: ["kind": .string("user"), "rpcId": requestId.map(JSONValue.string)]),
        ]))
    }

    /// The bug this exists for: the harness mints its own id, so the echoed
    /// message could never match the optimistic bubble by it, and every single
    /// message a person sent appeared on screen twice. dsh 0.2 logs the
    /// sender's request id, and that is the join.
    func testTheRealMessageReplacesTheOptimisticOne() {
        let held = Conversation(sessionId: "s1")
        held.showPending(text: "what model are you", id: "req-1")
        XCTAssertEqual(held.items.count, 1)

        held.apply(event: userMessage("what model are you", id: "m-abc", seq: 5, requestId: "req-1"))

        XCTAssertEqual(held.items.count, 1, "the message must appear once, not twice")
        guard case .user(let user) = held.items[0] else { return XCTFail("expected a user turn") }
        XCTAssertEqual(user.id, "m-abc", "the surviving copy is the real one, so later events can address it")
    }

    /// Two sends of the same text consume one bubble each — the one each was
    /// sent under.
    func testRepeatedTextClearsOneBubblePerEcho() {
        let held = Conversation(sessionId: "s1")
        held.showPending(text: "again", id: "req-1")
        held.showPending(text: "again", id: "req-2")

        held.apply(event: userMessage("again", id: "m-2", seq: 5, requestId: "req-2"))
        XCTAssertEqual(held.items.map(\.id), ["req-1", "m-2"])

        held.apply(event: userMessage("again", id: "m-1", seq: 6, requestId: "req-1"))
        XCTAssertEqual(held.items.map(\.id), ["m-2", "m-1"], "both real copies, no optimistic leftovers")
    }

    /// A message from somewhere else — the web UI, another phone — must not eat
    /// an outstanding optimistic bubble, even one that reads the same.
    func testAnUnrelatedMessageStillAppends() {
        let held = Conversation(sessionId: "s1")
        held.showPending(text: "same words", id: "req-1")
        held.apply(event: userMessage("same words", id: "m-1", seq: 5, requestId: "web-1"))
        XCTAssertEqual(held.items.count, 2, "no match means nothing is removed")
    }

    /// A failed send drops its bubble and leaves nothing behind to match later.
    func testAFailedSendLeavesNoGhost() {
        let held = Conversation(sessionId: "s1")
        held.showPending(text: "lost", id: "req-1")
        held.dropPending(id: "req-1")
        XCTAssertTrue(held.items.isEmpty)

        held.apply(event: userMessage("lost", id: "m-1", seq: 5, requestId: "req-1"))
        XCTAssertEqual(held.items.count, 1, "a later real message is unaffected by the dropped bubble")
    }
}
