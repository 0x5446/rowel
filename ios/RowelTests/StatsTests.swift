/// The projections that were arriving and being discarded.
///
/// These are folded from the same `session/projection` frames the machine
/// already sends, so the shapes here are copied from a live harness rather than
/// invented — if dsh changes one, this is where it should fail.

import XCTest
@testable import Rowel

@MainActor
final class SessionStatsFoldTests: XCTestCase {
    private func conversation() -> Conversation { Conversation(sessionId: "s1") }

    /// Decoded from text rather than built with literals, so what these tests
    /// exercise is the same path a frame off the wire takes.
    private func json(_ text: String) -> JSONValue {
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    // MARK: - Folding

    func testStatsFold() {
        let c = conversation()
        c.applyProjection(key: "sessionStats", value: json("""
        {"turns":5,"steps":38,"llmMs":330000,"toolMs":3400,"ttftMs":34000,"ttftSteps":5,"decodeMs":92000,"decodeTokens":8100}
        """), seq: 1)

        XCTAssertEqual(c.stats?.turns, 5)
        XCTAssertEqual(c.stats?.steps, 38)
        XCTAssertEqual(c.stats?.averageTtftMs, 6_800, "the machine sends a sum and a count, not a mean")
        XCTAssertEqual(c.stats?.tokensPerSecond ?? 0, 88, accuracy: 0.5)
    }

    func testStatsBeforeAnythingHasRun() {
        let c = conversation()
        c.applyProjection(key: "sessionStats", value: json("""
        {"turns":0,"steps":0,"llmMs":0,"toolMs":0,"ttftMs":0,"ttftSteps":0,"decodeMs":0,"decodeTokens":0}
        """), seq: 1)

        // Nil rather than zero: a zero would be drawn as "0 tok/s", which reads
        // as stalled rather than as not started.
        XCTAssertNil(c.stats?.averageTtftMs)
        XCTAssertNil(c.stats?.tokensPerSecond)
    }

    func testTokenUsageFold() {
        let c = conversation()
        c.applyProjection(key: "tokenUsage", value: json("""
        {"uncachedInputTokens":6,"outputTokens":13,"cacheReadTokens":12800,"cacheWriteTokens":0}
        """), seq: 1)

        XCTAssertEqual(c.tokens?.totalInput, 12_806)
        XCTAssertEqual(c.tokens?.cacheHitRate ?? 0, 0.9995, accuracy: 0.001)
    }

    func testCacheRateIsNilRatherThanZeroBeforeAnyInput() {
        let c = conversation()
        c.applyProjection(key: "tokenUsage", value: json("""
        {"uncachedInputTokens":0,"outputTokens":0,"cacheReadTokens":0,"cacheWriteTokens":0}
        """), seq: 1)

        // "no requests yet" and "every request missed the cache" are different
        // facts and 0% would state the second.
        XCTAssertNil(c.tokens?.cacheHitRate)
    }

    func testContextPressureKeepsTheRawNumbersAsWellAsTheFraction() {
        let c = conversation()
        c.applyProjection(key: "contextPressure", value: json("""
        {"pressureTokens":12806,"projectedTokens":12829,"contextWindow":1000000}
        """), seq: 1)

        XCTAssertEqual(c.contextTokens, 12_829, "projected wins over pressure")
        XCTAssertEqual(c.contextWindow, 1_000_000)
        XCTAssertEqual(c.contextFraction ?? 0, 0.0128, accuracy: 0.0005)
    }

    func testContextBreakdownFold() {
        let c = conversation()
        c.applyProjection(key: "contextBreakdown", value: json("""
        {"systemTokens":1512,"toolsTokens":6376,"messageTokens":3900}
        """), seq: 1)

        XCTAssertEqual(c.contextBreakdown?.total, 11_788)
    }

    func testPermissionsFold() {
        let c = conversation()
        c.applyProjection(key: "permissions", value: json("""
        {"options":[{"value":"read-only","name":"read-only"},
                    {"value":"workspace-write","name":"workspace-write"},
                    {"value":"danger-full-access","name":"danger-full-access"}],
         "currentValue":"workspace-write"}
        """), seq: 1)

        XCTAssertEqual(c.permissions?.current, "workspace-write")
        XCTAssertEqual(c.permissions?.options.count, 3)
        // The machine sends the raw value as the name; the app has to be the one
        // that turns `danger-full-access` into something readable.
        XCTAssertEqual(PermissionChoice.label(for: "danger-full-access"), "Full access")
    }

    func testCustomIsAStateRatherThanAChoice() {
        // The machine appends `custom` to `options` when a session's knobs match
        // no preset. It is what the session *is*, not something to switch to —
        // `/permission custom` is refused — so it must never reach the picker as
        // a target.
        let c = conversation()
        c.applyProjection(key: "permissions", value: json("""
        {"options":[{"value":"read-only","name":"read-only"},
                    {"value":"workspace-write","name":"workspace-write"},
                    {"value":"custom","name":"custom"}],
         "currentValue":"custom"}
        """), seq: 1)

        XCTAssertEqual(c.permissions?.current, "custom")
        XCTAssertEqual(c.permissions?.choices.map(\.value), ["read-only", "workspace-write"])
        XCTAssertEqual(PermissionChoice.label(for: "custom"), "Custom")
        XCTAssertFalse(PermissionChoice.detail(for: "custom").isEmpty,
                       "a mode with no preset still has to be explained on screen")
    }

    func testAStaleFrameCannotUndoANewerOne() {
        let c = conversation()
        c.applyProjection(key: "sessionStats", value: json("{\"turns\":9}"), seq: 20)
        c.applyProjection(key: "sessionStats", value: json("{\"turns\":1}"), seq: 3)

        XCTAssertEqual(c.stats?.turns, 9, "a reconnect can deliver these out of order")
    }

    func testAnUnknownKeyIsIgnoredRatherThanFatal() {
        let c = conversation()
        c.applyProjection(key: "somethingDshAddedLater", value: json("{\"x\":1}"), seq: 1)
        XCTAssertNil(c.stats)
    }
}

final class FormatTests: XCTestCase {
    func testTokenCountsAreCoarseAboveAThousand() {
        // Nobody compares 687,412 to 688,003.
        XCTAssertEqual(Format.tokens(0), "0")
        XCTAssertEqual(Format.tokens(999), "999")
        XCTAssertEqual(Format.tokens(1_200), "1.2k")
        XCTAssertEqual(Format.tokens(12_806), "13k")
        XCTAssertEqual(Format.tokens(688_000), "688k")
        XCTAssertEqual(Format.tokens(1_000_000), "1.0M")
    }

    func testDurationsUseTheLargestUsefulUnit() {
        XCTAssertEqual(Format.duration(ms: 340), "340ms")
        XCTAssertEqual(Format.duration(ms: 3_400), "3.4s")
        XCTAssertEqual(Format.duration(ms: 60_000), "1m")
        XCTAssertEqual(Format.duration(ms: 330_000), "5m 30s")
        XCTAssertEqual(Format.duration(ms: 3_720_000), "1h 2m")
    }
}

/// When the slash-command list should appear, and what it should offer.
///
/// The trigger is the whole design: it has to catch someone reaching for a name
/// they half-remember and get out of the way the moment they are writing a
/// message rather than a command.
final class CommandPrefixTests: XCTestCase {
    func testABareSlashOpensIt() {
        XCTAssertEqual(commandPrefix(in: "/"), "")
        XCTAssertEqual(commandPrefix(in: "/br"), "br")
        XCTAssertEqual(commandPrefix(in: "/competitor-teardown"), "competitor-teardown")
    }

    func testASpaceClosesIt() {
        // Past the first space they are writing arguments, and a list over the
        // transcript would be in the way rather than in the flow.
        XCTAssertNil(commandPrefix(in: "/bro "))
        XCTAssertNil(commandPrefix(in: "/bro explain this"))
    }

    func testTextThatMerelyContainsASlash() {
        XCTAssertNil(commandPrefix(in: "look at src/main.ts"))
        XCTAssertNil(commandPrefix(in: ""))
        XCTAssertNil(commandPrefix(in: "what does / mean here"))
    }

    func testAMultilineMessageStartingWithASlashIsNotACommand() {
        // Pasting a diff or a path list should not put a picker over the screen.
        XCTAssertNil(commandPrefix(in: "/etc/hosts\nand the other one"))
    }

    func testSummaryTakesTheFirstSentence() {
        let command = SkillCommand(.object([
            "name": .string("bro"),
            "description": .string("Re-explain the previous message simply. Use /bro to get a plain version."),
        ]))
        // These descriptions are written for a model, at model length; the first
        // sentence is what fits on a phone and usually all there is worth reading.
        XCTAssertEqual(command?.summary, "Re-explain the previous message simply")
    }

    func testSummaryHandlesAChineseFullStop() {
        let command = SkillCommand(.object([
            "name": .string("agently-mail"),
            "description": .string("通过命令行操作邮件：发送、回复、转发。当用户需要邮件操作时使用。"),
        ]))
        XCTAssertEqual(command?.summary, "通过命令行操作邮件：发送、回复、转发")
    }

    func testANamelessEntryIsDropped() {
        XCTAssertNil(SkillCommand(.object(["description": .string("no name")])))
    }
}

/// The trace's job is to turn a transcript into something scannable, so what is
/// worth testing is what it drops, how it splits, and how it flattens.
@MainActor
final class TraceEntryTests: XCTestCase {
    private func only(_ item: ConversationItem) -> TraceEntry? {
        TraceEntry.entries(for: item).first
    }

    private func assistant(text: String, reasoning: String, complete: Bool = true) -> ConversationItem {
        .assistant(AssistantTurn(
            id: "a1", turn: 2, step: 3, text: text, reasoning: reasoning,
            complete: complete, at: Date(timeIntervalSince1970: 1_700_000_000)
        ))
    }

    // MARK: - Splitting model output

    func testReasoningAndReplyAreTwoSteps() {
        // dsh draws these as a collapsed `Think` and the reply under it. Folding
        // them into one row loses the reasoning whenever there is also text.
        let made = TraceEntry.entries(for: assistant(text: "Here is the fix", reasoning: "The build fails in auth.ts"))

        XCTAssertEqual(made.count, 2)
        XCTAssertEqual(made[0].kind, .thinking)
        XCTAssertEqual(made[0].detail, "The build fails in auth.ts")
        XCTAssertEqual(made[1].kind, .reply)
        XCTAssertEqual(made[1].detail, "Here is the fix")
    }

    func testReasoningWithNoReplyIsNotLabelledAReply() {
        let made = TraceEntry.entries(for: assistant(text: "", reasoning: "Still looking"))
        XCTAssertEqual(made.map(\.kind), [.thinking])
        XCTAssertEqual(made[0].label, "Thinking")
    }

    func testAStepThatOnlyCalledAToolProducesNoModelRow() {
        // There is nothing to say about it; the tool row carries the step.
        XCTAssertTrue(TraceEntry.entries(for: assistant(text: "", reasoning: "")).isEmpty)
    }

    func testOnlyTheTailOfAStepIsRunning() {
        let made = TraceEntry.entries(for: assistant(text: "partial", reasoning: "done thinking", complete: false))
        XCTAssertEqual(made[0].running, false, "reasoning finished once text started")
        XCTAssertEqual(made[1].running, true)
    }

    func testReasoningJumpsToTheSharedBubble() {
        // Both halves live in one bubble on the transcript, so the synthetic id
        // has to come back off before scrolling to it.
        let made = TraceEntry.entries(for: assistant(text: "hi", reasoning: "hm"))
        XCTAssertEqual(made[0].id, "a1#think")
        XCTAssertEqual(made[0].transcriptId, "a1")
        XCTAssertEqual(made[1].transcriptId, "a1")
    }

    // MARK: - Other kinds

    func testInjectedContextIsItsOwnKind() {
        // Not dropped: it is a large part of where the context window went, and
        // the fold already carries dsh's short label for it.
        let entry = only(.user(UserTurn(
            id: "u1", text: "skill-catalog", images: [], synthetic: true, at: Date()
        )))
        XCTAssertEqual(entry?.kind, .context)
        XCTAssertEqual(entry?.label, "Context")
    }

    func testATypedMessageIsAUserStep() {
        let entry = only(.user(UserTurn(
            id: "u2", text: "fix the build", images: [], synthetic: false, at: Date()
        )))
        XCTAssertEqual(entry?.kind, .user)
        XCTAssertEqual(entry?.detail, "fix the build")
    }

    func testAFailedToolIsMarked() {
        let entry = only(.tool(ToolCard(
            id: "t1", name: "Bash", arguments: "{}",
            presentation: .terminal(command: "npm test", cwd: nil, output: nil, exitCode: 1),
            resultText: nil, failed: true, running: false,
            at: Date(timeIntervalSince1970: 1_700_000_000), finishedAt: nil
        )))
        XCTAssertEqual(entry?.failed, true)
        XCTAssertEqual(entry?.label, "Bash")
        XCTAssertEqual(entry?.detail, "npm test")
    }

    // MARK: - Timing

    func testAToolsDurationIsMeasuredNotInferred() {
        // Tools have both a call and a result timestamp, which is the only place
        // a real duration comes from — the events carry no duration field.
        let entry = only(.tool(ToolCard(
            id: "t2", name: "Bash", arguments: "{}",
            presentation: .terminal(command: "sleep 40", cwd: nil, output: nil, exitCode: 0),
            resultText: nil, failed: false, running: false,
            at: Date(timeIntervalSince1970: 1_700_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_700_000_040)
        )))
        XCTAssertEqual(entry?.took ?? 0, 40, accuracy: 0.01)
    }

    func testOtherKindsAreTimedByTheGapToTheNextStep() {
        let entries = TraceEntry.timed([
            TraceEntry(id: "a", kind: .reply, icon: "", label: "Reply", detail: "one",
                       at: Date(timeIntervalSince1970: 100), failed: false, running: false, step: nil, took: nil),
            TraceEntry(id: "b", kind: .reply, icon: "", label: "Reply", detail: "two",
                       at: Date(timeIntervalSince1970: 112), failed: false, running: false, step: nil, took: nil),
        ])
        XCTAssertEqual(entries[0].took ?? 0, 12, accuracy: 0.01)
        XCTAssertNil(entries[1].took, "the last step has no next one to measure against")
    }

    func testARunningStepIsNotGivenAnInventedEnd() {
        let entries = TraceEntry.timed([
            TraceEntry(id: "a", kind: .reply, icon: "", label: "Reply", detail: "one",
                       at: Date(timeIntervalSince1970: 100), failed: false, running: true, step: nil, took: nil),
            TraceEntry(id: "b", kind: .reply, icon: "", label: "Reply", detail: "two",
                       at: Date(timeIntervalSince1970: 130), failed: false, running: false, step: nil, took: nil),
        ])
        XCTAssertNil(entries[0].took)
    }

    func testSubSecondGapsAreNotShown() {
        // Noise on a phone row, and a wall of "0.2s" hides the one that says 40s.
        let entries = TraceEntry.timed([
            TraceEntry(id: "a", kind: .reply, icon: "", label: "Reply", detail: "one",
                       at: Date(timeIntervalSince1970: 100), failed: false, running: false, step: nil, took: nil),
            TraceEntry(id: "b", kind: .reply, icon: "", label: "Reply", detail: "two",
                       at: Date(timeIntervalSince1970: 100.3), failed: false, running: false, step: nil, took: nil),
        ])
        XCTAssertNil(entries[0].took)
    }

    // MARK: - Flattening

    func testMultilineOutputCollapsesToOneLine() {
        XCTAssertEqual(TraceEntry.oneLine("first\n\nsecond   third\nfourth"), "first second third fourth")
    }

    func testAVeryLongLineIsTruncated() {
        let flattened = TraceEntry.oneLine(String(repeating: "x", count: 500))
        XCTAssertEqual(flattened.count, 201, "200 characters plus the ellipsis")
        XCTAssertTrue(flattened.hasSuffix("…"))
    }

    func testSearchMatchesTheArgumentAsWellAsTheTool() {
        let entry = only(.tool(ToolCard(
            id: "t3", name: "Read", arguments: "{}",
            presentation: .read(path: "/src/auth.ts", lines: [], totalLines: 0),
            resultText: nil, failed: false, running: false, at: Date(), finishedAt: nil
        )))
        XCTAssertTrue(entry?.searchText.contains("auth.ts") == true)
        XCTAssertTrue(entry?.searchText.contains("Read") == true)
    }
}

/// The four token classes, which are four prices and must not be summed away.
@MainActor
final class TokenBreakdownTests: XCTestCase {
    private func usage(_ text: String) -> TokenUsage? {
        // swiftlint:disable:next force_try
        TokenUsage(try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)))
    }

    func testAllFourSurvive() {
        let t = usage("""
        {"uncachedInputTokens":6,"outputTokens":13,"cacheReadTokens":12800,"cacheWriteTokens":420}
        """)
        XCTAssertEqual(t?.uncachedInput, 6)
        XCTAssertEqual(t?.cacheWrite, 420)
        XCTAssertEqual(t?.cacheRead, 12_800)
        XCTAssertEqual(t?.output, 13)
    }

    func testTotalInputCountsEveryKindThatWasBilledAsInput() {
        // Writes are billed as input too, and at a premium — leaving them out
        // of the denominator would flatter the hit rate.
        let t = usage("""
        {"uncachedInputTokens":100,"outputTokens":0,"cacheReadTokens":300,"cacheWriteTokens":100}
        """)
        XCTAssertEqual(t?.totalInput, 500)
        XCTAssertEqual(t?.cacheHitRate ?? 0, 0.6, accuracy: 0.001)
    }
}

/// The live line under "Thinking…".
final class ReasoningTailTests: XCTestCase {
    func testTheNewestLineWins() {
        XCTAssertEqual(
            AssistantBlock.tail(of: "First I check the build.\nThen the auth module."),
            "Then the auth module."
        )
    }

    func testATrailingNewlineDoesNotBlankTheRow() {
        // Deltas land mid-prose, and one arriving just after a paragraph break
        // would leave an empty last line — the row would flicker off and back
        // several times a second.
        XCTAssertEqual(AssistantBlock.tail(of: "Looking at auth.ts\n\n"), "Looking at auth.ts")
        XCTAssertEqual(AssistantBlock.tail(of: "Looking at auth.ts\n   \n"), "Looking at auth.ts")
    }

    func testNothingYetIsEmptyRatherThanWhitespace() {
        XCTAssertEqual(AssistantBlock.tail(of: ""), "")
        XCTAssertEqual(AssistantBlock.tail(of: "\n \n"), "")
    }

    func testASingleUnbrokenLineIsItself() {
        // The common case early in a turn: no newline has arrived yet.
        XCTAssertEqual(AssistantBlock.tail(of: "The user is asking about"), "The user is asking about")
    }
}
