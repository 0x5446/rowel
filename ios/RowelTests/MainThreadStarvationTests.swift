/// Does following the tail starve the main thread?
///
/// Field symptom: a big conversation (~178 steps) is running, the person sends
/// a message (which sets `atBottom = true`), and for tens of seconds the
/// transcript will not scroll — touch delivery depends on the main run loop
/// turning, and it is not turning.
///
/// Hypothesis H1: while `atBottom == true`, every streamed delta changes
/// `lastLength`, whose `onChange` does an unanimated `proxy.scrollTo` to the
/// bottom anchor; at streaming rates that scroll storm, stacked on the per-
/// delta fold and re-render, saturates the main thread.
///
/// The experiment mounts the *real* `ConversationView` in a real `UIWindow`
/// inside the host app, preloads a large transcript, then injects reasoning
/// and text deltas at a fixed 35 Hz for 5 seconds through the same main-actor
/// path the tunnel pump uses. A `CADisplayLink` on the main run loop is the
/// responsiveness probe: the fraction of missed ticks and the longest single
/// gap are the proxy for "the scroll gesture is dead".
///
/// Three conditions on identical data and an identical injection schedule:
///  - A: view mounted, `atBottom` starts true  (the post-send state)
///  - B: view mounted, `atBottom` starts false (the scrolled-away state)
///  - C: no view mounted at all               (pure fold, no rendering)
///
/// A ≫ B  ⇒ the scroll-to-bottom storm is the saturator (H1 holds).
/// A ≈ B, both bad ⇒ the per-delta fold/re-render is the saturator (H2).
/// A ≈ B ≈ smooth ⇒ neither; the hypothesis is refuted at this scale.
///
/// These tests measure and report; they only assert that the experiment
/// itself ran (all events injected, the probe ticked, the view was mounted).
/// The numbers are printed on lines starting with `[H1EXP]` and appended to
/// /tmp/rowel-h1-results.log so they survive the log noise.

import XCTest
import SwiftUI
import UIKit
import QuartzCore
@testable import Rowel

// MARK: - Transport

/// Answers every harness call with an empty object. The reads the view fires
/// on open (history, models, skills, subagents) all tolerate that shape; the
/// transcript under test is preloaded directly into the `Conversation`.
private actor SilentTransport: HarnessTransport {
    func call(_ method: String, _ payload: JSONValue) async throws -> JSONValue { .emptyObject }
    func respond(rpcId: String, value: JSONValue) async throws -> JSONValue { .emptyObject }
}

// MARK: - Responsiveness probe

/// Counts display-link ticks on the main run loop. When the main thread is
/// busy inside a body evaluation, layout, or commit, the link cannot fire and
/// the gap between consecutive timestamps grows — the same starvation that
/// keeps a pan gesture from being delivered.
@MainActor
private final class FrameMeter: NSObject {
    private var link: CADisplayLink?
    private(set) var stamps: [CFTimeInterval] = []

    func start() {
        stamps.removeAll(keepingCapacity: true)
        stamps.reserveCapacity(8192)
        let made = CADisplayLink(target: self, selector: #selector(tick(_:)))
        made.add(to: .main, forMode: .common)
        link = made
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ sender: CADisplayLink) {
        stamps.append(sender.timestamp)
    }

    struct Stats {
        var ticks = 0
        var windowSeconds = 0.0
        /// 1 − observed/expected ticks, given the display's refresh rate.
        var dropRate = 0.0
        var maxGapMs = 0.0
        var p95GapMs = 0.0
        var gapsOver50 = 0
        var gapsOver100 = 0
        var gapsOver250 = 0
        var gapsOver1000 = 0
    }

    /// - Parameter within: restrict to ticks inside this absolute time range
    ///   (CACurrentMediaTime domain), for phase-resolved readings.
    func stats(fps: Double, within range: ClosedRange<CFTimeInterval>? = nil) -> Stats {
        let picked = range.map { r in stamps.filter { r.contains($0) } } ?? stamps
        guard picked.count >= 2 else { return Stats(ticks: picked.count) }
        var gaps: [Double] = []
        gaps.reserveCapacity(picked.count - 1)
        for index in 1..<picked.count {
            gaps.append(picked[index] - picked[index - 1])
        }
        let window = picked[picked.count - 1] - picked[0]
        let expected = window * fps
        let sorted = gaps.sorted()
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        return Stats(
            ticks: picked.count,
            windowSeconds: window,
            dropRate: expected > 0 ? max(0, 1 - Double(gaps.count) / expected) : 0,
            maxGapMs: (sorted.last ?? 0) * 1000,
            p95GapMs: p95 * 1000,
            gapsOver50: gaps.filter { $0 > 0.050 }.count,
            gapsOver100: gaps.filter { $0 > 0.100 }.count,
            gapsOver250: gaps.filter { $0 > 0.250 }.count,
            gapsOver1000: gaps.filter { $0 > 1.000 }.count
        )
    }
}

// MARK: - Deterministic content

/// No randomness anywhere: two runs, and the two conditions within a run,
/// fold byte-identical transcripts and inject byte-identical deltas.
private enum Corpus {
    static let words = [
        "the", "agent", "reads", "the", "file", "and", "rewrites", "what", "it",
        "found", "then", "runs", "the", "tests", "again", "until", "they", "pass",
        "while", "noting", "every", "change", "in", "a", "long", "careful", "list",
        "of", "steps", "that", "keeps", "growing", "as", "the", "session", "does",
    ]

    static func prose(_ count: Int, seed: Int) -> String {
        (0..<count).map { words[(seed &+ $0 &* 7) % words.count] }.joined(separator: " ")
    }

    /// ~1.3 KB of markdown: heading, paragraph, list, code fence, paragraph.
    static func markdownBody(_ index: Int) -> String {
        var made = "### Step \(index): what changed\n\n"
        made += prose(60, seed: index) + "\n\n"
        made += "- " + prose(8, seed: index + 1) + "\n"
        made += "- " + prose(9, seed: index + 2) + "\n"
        made += "- " + prose(7, seed: index + 3) + "\n\n"
        made += "```swift\nfunc step\(index)() {\n    let value = compute(\(index))\n    print(value)\n}\n```\n\n"
        made += prose(50, seed: index + 4)
        return made
    }

    /// ~40 KB of build-log-shaped tool output.
    static func bigToolOutput(seed: Int) -> String {
        (0..<500).map { line in
            "\(line): warning: " + prose(9, seed: seed &+ line) + " (\(line % 97))"
        }.joined(separator: "\n")
    }

    /// Reasoning prose with paragraph breaks — the state of a thinking block
    /// that has already been going for a while. ~0.5 KB per paragraph.
    static func initialReasoning(paragraphs: Int) -> String {
        (0..<paragraphs).map { prose(70, seed: 9000 + $0) }.joined(separator: "\n\n")
    }

    /// Already-streamed answer text in the open bubble, ~1.4 KB per copy of
    /// structured markdown plus a lead-in paragraph.
    static func initialStreamText(copies: Int) -> String {
        var made = prose(80, seed: 7000) + "\n\n" + "Here is the `first` part of the **answer** so far.\n\n"
        for copy in 0..<copies {
            made += markdownBody(700 + copy) + "\n\n"
        }
        return made + prose(120, seed: 7100)
    }

    /// One reasoning delta, ~60–70 chars, with an occasional newline so the
    /// tail-line extractor sees realistic paragraph breaks.
    static func reasoningDelta(_ k: Int) -> String {
        prose(9, seed: 2000 + k) + (k % 7 == 3 ? "\n" : " ")
    }

    /// One answer-text delta, ~60–70 chars, with occasional inline markdown.
    static func textDelta(_ k: Int) -> String {
        switch k % 9 {
        case 2: return "`" + prose(2, seed: 3000 + k) + "` " + prose(6, seed: 3100 + k) + " "
        case 5: return "**" + prose(2, seed: 3200 + k) + "** " + prose(6, seed: 3300 + k) + " "
        case 7: return prose(8, seed: 3400 + k) + "\n\n"
        default: return prose(9, seed: 3500 + k) + " "
        }
    }
}

// MARK: - The experiment

@MainActor
final class MainThreadStarvationTests: XCTestCase {
    private let sessionId = "session-starvation-experiment"

    /// Injection: 35 Hz for 5 s — 175 deltas, reasoning first, then text.
    private let deltaHz = 35.0
    private let reasoningDeltas = 90
    private let textDeltas = 85
    /// Measurement window: however long the injection takes, plus a tail for
    /// trailing work. Derived rather than fixed, because the rate is now one of
    /// the things a condition can vary.

    /// How big the open streaming bubble is when the stream starts. The field
    /// symptom came from a 178-step session; how much of it the current
    /// bubble holds is the one number the diagnosis could not read off the
    /// device, so the experiment states two points on that axis.
    private struct BubbleScale {
        /// ~12 KB reasoning + ~3 KB text: a modest turn.
        static let modest = BubbleScale(reasoningParagraphs: 24, textCopies: 1)
        /// ~48 KB reasoning + ~16 KB text: a long thinking block mid-answer.
        static let heavy = BubbleScale(reasoningParagraphs: 128, textCopies: 18)
        /// ~190 KB reasoning + ~60 KB text: the far end of what one step of a
        /// very long session can hold. If the follow-tail path scales badly,
        /// this is where it shows.
        static let giant = BubbleScale(reasoningParagraphs: 512, textCopies: 72)
        var reasoningParagraphs: Int
        var textCopies: Int
    }

    // Condition A: the post-send state. `atBottom == true`, so every delta's
    // `lastLength` change fires an unanimated scrollTo(bottom).
    func testA_streamingWhileFollowingTail() {
        runExperiment(condition: "A", mountView: true, initiallyAtBottom: true, scale: .modest)
    }

    // Condition B: the scrolled-away state. Identical data, identical stream,
    // identical rendering — the per-delta scrollTo is the only thing missing.
    func testB_streamingScrolledAway() {
        runExperiment(condition: "B", mountView: true, initiallyAtBottom: false, scale: .modest)
    }

    // Condition C: no view at all. Isolates the fold itself from rendering.
    func testC_streamingWithNoViewMounted() {
        runExperiment(condition: "C", mountView: false, initiallyAtBottom: false, scale: .modest)
    }

    // D/E/F: the same triple with a heavy open bubble, because a rig that is
    // smooth everywhere proves nothing until something on it can be made to
    // stall — and because the field session's bubble was not a modest one.
    func testD_heavyStreamFollowingTail() {
        runExperiment(condition: "D", mountView: true, initiallyAtBottom: true, scale: .heavy)
    }

    func testE_heavyStreamScrolledAway() {
        runExperiment(condition: "E", mountView: true, initiallyAtBottom: false, scale: .heavy)
    }

    func testF_heavyStreamNoView() {
        runExperiment(condition: "F", mountView: false, initiallyAtBottom: false, scale: .heavy)
    }

    // G/H: the giant bubble, follow-tail against scrolled-away, to read the
    // scaling law off the pair — is the extra cost of following the tail
    // growing faster than the cost everything else shares?
    func testG_giantStreamFollowingTail() {
        runExperiment(condition: "G", mountView: true, initiallyAtBottom: true, scale: .giant)
    }

    func testH_giantStreamScrolledAway() {
        runExperiment(condition: "H", mountView: true, initiallyAtBottom: false, scale: .giant)
    }

    // I: the giant bubble with no view mounted — if the fold alone stays
    // free at this scale, everything G and H pay is rendering.
    func testI_giantStreamNoView() {
        runExperiment(condition: "I", mountView: false, initiallyAtBottom: false, scale: .giant)
    }

    // K: the same giant bubble as G/H, but injected at the rate the field
    // symptom's harness actually streams — about two hundred tokens a second,
    // not the thirty-five every other condition uses. If G and H looked calm it
    // was only because they were starved of deltas, and the field symptom is
    // "send a message and the screen stops answering".
    func testK_giantStreamAtWireRate() {
        runExperiment(
            condition: "K", mountView: true, initiallyAtBottom: true, scale: .giant,
            hz: 200, reasoningCount: 360, textCount: 240
        )
    }

    // J: not an A/B condition — a cost attribution. `MarkdownText` runs
    // `Markdown.parse` over the *entire* accumulated source on every render,
    // and every text delta is a render. This measures that parse alone, off
    // any view, so the per-delta stall G and H showed can be split into
    // "parsing the whole bubble again" and "everything SwiftUI does after".
    func testJ_markdownParseCostAlone() {
        for (name, copies) in [("modest", 1), ("heavy", 18), ("giant", 72)] {
            let source = Corpus.initialStreamText(copies: copies)
            _ = Markdown.parse(source) // warm caches, fault code paths
            var blocks: [MarkdownBlock] = []
            let started = CACurrentMediaTime()
            for _ in 0..<10 { blocks = Markdown.parse(source) }
            let msPerParse = (CACurrentMediaTime() - started) / 10 * 1000

            // The other per-render cost `MarkdownText` pays: `Markdown.inline`
            // — an AttributedString markdown parse — for every textual block,
            // because the whole VStack's ForEach re-evaluates each render.
            var inlines = 0
            let inlineStart = CACurrentMediaTime()
            for _ in 0..<10 {
                inlines = 0
                for block in blocks {
                    switch block {
                    case .paragraph(let text), .quote(let text), .heading(_, let text):
                        _ = Markdown.inline(text)
                        inlines += 1
                    case .bullet(let items, _):
                        for item in items { _ = Markdown.inline(item) }
                        inlines += items.count
                    case .code, .table, .rule:
                        break
                    }
                }
            }
            let msPerInlinePass = (CACurrentMediaTime() - inlineStart) / 10 * 1000

            let line = String(
                format: "[H1EXP] parseBench scale=%@ bytes=%d blocks=%d msPerParse=%.2f inlineRuns=%d msPerInlinePass=%.2f",
                name, source.utf8.count, blocks.count, msPerParse, inlines, msPerInlinePass
            )
            print(line)
            NSLog("%@", line)
            append(line: line)
            XCTAssertGreaterThan(blocks.count, 0)
        }
    }

    // MARK: Runner

    private func runExperiment(
        condition: String, mountView: Bool, initiallyAtBottom: Bool, scale: BubbleScale,
        hz: Double? = nil, reasoningCount: Int? = nil, textCount: Int? = nil
    ) {
        let deltaHz = hz ?? self.deltaHz
        let reasoningDeltas = reasoningCount ?? self.reasoningDeltas
        let textDeltas = textCount ?? self.textDeltas
        let measureSeconds = Double(reasoningDeltas + textDeltas) / deltaHz + 1.0
        let session = makeSession()
        let conversation = session.conversation(sessionId)
        var seq = 1
        preload(conversation, seq: &seq, scale: scale)
        XCTAssertGreaterThan(conversation.items.count, 150, "the transcript under test is a big one")
        XCTAssertTrue(conversation.running, "the field symptom happens mid-turn")
        var bubbleReasoning = 0
        var bubbleText = 0
        if case .assistant(let turn)? = conversation.items.last {
            bubbleReasoning = turn.reasoning.count
            bubbleText = turn.text.count
        }

        var window: UIWindow?
        if mountView {
            window = mount(session: session, initiallyAtBottom: initiallyAtBottom)
            // Let the first layout, `.task`, and the onAppear scroll settle.
            pump(seconds: 2.5)
            XCTAssertNotNil(window?.rootViewController?.view.window, "the view under test must actually be on screen")
        }

        let fps = Double(window?.windowScene?.screen.maximumFramesPerSecond ?? 60)

        // Baseline: one second of nothing, to prove the probe reads ~0 when
        // the main thread is healthy.
        let idleMeter = FrameMeter()
        idleMeter.start()
        pump(seconds: 1.0)
        idleMeter.stop()
        let idle = idleMeter.stats(fps: fps)

        // The stream. A fixed schedule with catch-up: a driver tick injects
        // every delta that is past due, so a stalled main thread delays
        // deltas but never drops them — both conditions always inject all 175.
        var plan: [(offset: Double, signal: TunnelSignal)] = []
        for k in 0..<(reasoningDeltas + textDeltas) {
            let kind = k < reasoningDeltas ? "reasoning-delta" : "text-delta"
            let text = k < reasoningDeltas ? Corpus.reasoningDelta(k) : Corpus.textDelta(k - reasoningDeltas)
            plan.append((Double(k) / deltaHz, chunkSignal(seq: seq, kind: kind, text: text)))
            seq += 1
        }

        var next = 0
        var maxLagMs = 0.0
        let meter = FrameMeter()
        meter.start()
        let started = CACurrentMediaTime()
        let driver = Timer(timeInterval: 1.0 / 120.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                let elapsed = CACurrentMediaTime() - started
                while next < plan.count, plan[next].offset <= elapsed {
                    maxLagMs = max(maxLagMs, (elapsed - plan[next].offset) * 1000)
                    session.receiveForTesting(plan[next].signal)
                    next += 1
                }
            }
        }
        RunLoop.main.add(driver, forMode: .common)

        let hardDeadline = Date().addingTimeInterval(60)
        while (CACurrentMediaTime() - started < measureSeconds || next < plan.count), Date() < hardDeadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        driver.invalidate()
        meter.stop()

        XCTAssertEqual(next, plan.count, "every condition must inject the whole stream")
        XCTAssertGreaterThan(meter.stamps.count, 10, "the probe never ticked; the measurement is void")

        let busy = meter.stats(fps: fps)
        // Phase-resolved: the first 90 deltas are reasoning, the rest text,
        // so the boundary separates "thinking tail-line" cost from
        // "markdown re-parse" cost.
        let boundary = started + Double(reasoningDeltas) / deltaHz
        let phase1 = meter.stats(fps: fps, within: started...boundary)
        let phase2 = meter.stats(fps: fps, within: boundary...(started + measureSeconds))
        report(
            condition: condition, mounted: mountView, followTail: initiallyAtBottom,
            items: conversation.items.count,
            bubbleReasoning: bubbleReasoning, bubbleText: bubbleText,
            injected: next, fps: fps,
            idle: idle, busy: busy, phase1: phase1, phase2: phase2, maxLagMs: maxLagMs
        )

        window?.isHidden = true
        window?.rootViewController = nil
    }

    // MARK: Reporting

    private func report(
        condition: String, mounted: Bool, followTail: Bool, items: Int,
        bubbleReasoning: Int, bubbleText: Int, injected: Int,
        fps: Double, idle: FrameMeter.Stats, busy: FrameMeter.Stats,
        phase1: FrameMeter.Stats, phase2: FrameMeter.Stats, maxLagMs: Double
    ) {
        let line = String(
            format: "[H1EXP] cond=%@ mounted=%@ followTail=%@ items=%d bubbleReasoningB=%d bubbleTextB=%d injected=%d fps=%.0f "
                + "idleMaxGapMs=%.1f idleDropRate=%.3f "
                + "ticks=%d windowS=%.2f dropRate=%.3f maxGapMs=%.1f p95GapMs=%.1f "
                + "over50=%d over100=%d over250=%d over1000=%d "
                + "reasonPhaseDrop=%.3f reasonPhaseMaxGapMs=%.1f textPhaseDrop=%.3f textPhaseMaxGapMs=%.1f "
                + "injectMaxLagMs=%.1f",
            condition, String(mounted), String(followTail), items, bubbleReasoning, bubbleText, injected, fps,
            idle.maxGapMs, idle.dropRate,
            busy.ticks, busy.windowSeconds, busy.dropRate, busy.maxGapMs, busy.p95GapMs,
            busy.gapsOver50, busy.gapsOver100, busy.gapsOver250, busy.gapsOver1000,
            phase1.dropRate, phase1.maxGapMs, phase2.dropRate, phase2.maxGapMs,
            maxLagMs
        )
        print(line)
        NSLog("%@", line)
        append(line: line)
    }

    /// The simulator writes straight to the host's /tmp, so the numbers
    /// survive however much noise xcodebuild wraps around stdout.
    private func append(line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        let path = "/tmp/rowel-h1-results.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }

    // MARK: Fixtures

    private func makeSession() -> MachineSession {
        let bundle = PairingBundle(
            relay: "https://relay.invalid", direct: nil, device: "device-1",
            key: "", token: "", name: "Test Mac"
        )
        let suite = UserDefaults(suiteName: "starvation-tests-\(UUID().uuidString)")!
        return MachineSession(
            machine: PairedMachine(bundle: bundle),
            identity: .generate(),
            deviceName: "Test iPhone",
            clientVersion: "rowel-tests/1",
            pairingToken: nil,
            notifier: Notifier(center: nil),
            defaults: suite,
            transport: SilentTransport()
        )
    }

    /// 181 items: 60 × (user message, ~1.3 KB markdown answer, tool card),
    /// four of the tool cards carrying ~40 KB outputs, then an open turn with
    /// a streaming assistant bubble holding ~12 KB of reasoning and ~3 KB of
    /// text — the state a heavy session is in when the person hits send.
    private func preload(_ conversation: Conversation, seq: inout Int, scale: BubbleScale) {
        func apply(_ type: String, _ data: JSONValue) {
            conversation.apply(event: .object([
                "type": .string(type),
                "seq": .number(Double(seq)),
                "time": .number(1_700_000_000_000 + Double(seq)),
                "data": data,
            ]), view: nil)
            seq += 1
        }

        for block in 0..<60 {
            apply("user/message", .object([
                "id": .string("u\(block)"),
                "source": .object(["kind": .string("user")]),
                "content": .array([
                    .object(["type": .string("text"), "text": .string("Please do step \(block): " + Corpus.prose(10, seed: block))]),
                ]),
            ]))
            apply("assistant/message", .object([
                "turn": .number(Double(block)),
                "step": .number(0),
                "message": .object([
                    "content": .array([
                        .object(["type": .string("text"), "text": .string(Corpus.markdownBody(block))]),
                    ]),
                ]),
            ]))
            let callId = "call-\(block)"
            apply("tool/call", .object([
                "callId": .string(callId),
                "name": .string("Bash"),
                "arguments": .string("{\"command\":\"make step\(block)\"}"),
            ]))
            let output = block % 15 == 7
                ? Corpus.bigToolOutput(seed: block)
                : "step \(block) ok\n" + Corpus.prose(20, seed: block + 500)
            apply("tool/result", .object([
                "message": .object([
                    "source": .object(["callId": .string(callId)]),
                    "content": .array([
                        .object([
                            "toolCallId": .string(callId),
                            "content": .array([
                                .object(["type": .string("text"), "text": .string(output)]),
                            ]),
                        ]),
                    ]),
                ]),
            ]))
        }

        apply("turn/start", .emptyObject)
        apply("assistant/chunk", .object([
            "turn": .number(999), "step": .number(0),
            "chunk": .object([
                "type": .string("reasoning-delta"),
                "text": .string(Corpus.initialReasoning(paragraphs: scale.reasoningParagraphs)),
            ]),
        ]))
        apply("assistant/chunk", .object([
            "turn": .number(999), "step": .number(0),
            "chunk": .object([
                "type": .string("text-delta"),
                "text": .string(Corpus.initialStreamText(copies: scale.textCopies)),
            ]),
        ]))
    }

    /// One streamed delta, wrapped the way the tunnel pump would hand it over.
    private func chunkSignal(seq: Int, kind: String, text: String) -> TunnelSignal {
        .event(EventFrame(seq: seq, stream: .mux, frame: .object([
            "type": .string("session/event"),
            "sessionId": .string(sessionId),
            "event": .object([
                "type": .string("assistant/chunk"),
                "seq": .number(Double(seq)),
                "time": .number(1_700_000_000_000 + Double(seq)),
                "data": .object([
                    "turn": .number(999),
                    "step": .number(0),
                    "chunk": .object(["type": .string(kind), "text": .string(text)]),
                ]),
            ]),
        ])))
    }

    // MARK: Plumbing

    private func mount(session: MachineSession, initiallyAtBottom: Bool) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        let window: UIWindow
        if let scene {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        }
        let host = UIHostingController(rootView: NavigationStack {
            ConversationView(
                session: session,
                sessionId: sessionId,
                initiallyAtBottom: initiallyAtBottom
            )
        })
        window.rootViewController = host
        window.makeKeyAndVisible()
        return window
    }

    private func pump(seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }
}
