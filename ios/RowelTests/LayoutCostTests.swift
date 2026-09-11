/// What does the first layout of a transcript cost?
///
/// Four crash reports off the device (2026-09-07 through 09-11, build 138) are
/// all the same shape: `0x8BADF00D`, main thread inside SwiftUI layout, app in
/// the background, killed either for "failed to terminate gracefully after
/// 5.0s" or for a scene-update that "exhausted real (wall clock) time allowance
/// of 10.00 seconds". Two of the four were sampled inside
/// `UITextView._intrinsicSizeWithinSize:` reached from
/// `TextViewAdaptor._overrideSizeThatFits` — a UIKit text view being measured
/// from inside a SwiftUI layout pass.
///
/// `MainThreadStarvationTests` cannot see this: it deliberately waits 2.5 s
/// after mounting "to let the first layout settle" and only then starts
/// measuring. The first layout is the thing that crashes, so this file measures
/// exactly the window that one discards.
///
/// Two questions, one per test:
///
///  1. Where do the UITextViews come from? The transcript has no `TextEditor`
///     in it, but every markdown paragraph carries `.textSelection(.enabled)`.
///     If that modifier is what backs a `Text` with a UIKit text view, the cost
///     scales with the number of paragraphs on screen and the crash stack is
///     explained. Counting the views answers it without guessing.
///
///  2. How does first-layout time scale with transcript size? Linear and small
///     is a big view that is fine. Superlinear, or seconds at a realistic size,
///     is the freeze.
///
/// Both tests report and assert only that the experiment ran. The numbers print
/// on lines starting with `[LAYOUT]` and are appended to
/// /tmp/rowel-layout-results.log.

import XCTest
import SwiftUI
import UIKit
import QuartzCore
@testable import Rowel

private actor QuietTransport: HarnessTransport {
    func call(_ method: String, _ payload: JSONValue) async throws -> JSONValue { .emptyObject }
    func respond(rpcId: String, value: JSONValue) async throws -> JSONValue { .emptyObject }
}

@MainActor
final class LayoutCostTests: XCTestCase {

    // MARK: 1 — what backs a selectable Text

    /// Mount the same paragraphs twice, once selectable and once not, and count
    /// the UIKit text views underneath. A difference is the mechanism the crash
    /// stack shows; no difference rules it out and sends the search elsewhere.
    func testSelectableTextBacking() {
        let paragraphs = (0..<40).map { "Paragraph \($0). " + Self.prose(40, seed: $0) }

        let plain = mountRaw(
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, text in
                    Text(text).font(.system(size: 15))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        )
        let plainCounts = Self.census(plain.rootViewController!.view)

        let selectable = mountRaw(
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, text in
                    Text(text).font(.system(size: 15))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        )
        let selectableCounts = Self.census(selectable.rootViewController!.view)

        let plainTextViews = Self.textViews(in: plainCounts)
        let selectableTextViews = Self.textViews(in: selectableCounts)

        emit(String(
            format: "[LAYOUT] selectableBacking paragraphs=%d plainTextViews=%d selectableTextViews=%d",
            paragraphs.count, plainTextViews, selectableTextViews
        ))
        emit("[LAYOUT]   plain hierarchy: \(Self.describe(plainCounts))")
        emit("[LAYOUT]   selectable hierarchy: \(Self.describe(selectableCounts))")

        teardown(plain)
        teardown(selectable)
        XCTAssertFalse(paragraphs.isEmpty)
    }

    // MARK: 2 — first-layout cost against transcript size

    /// The real `ConversationView`, preloaded, mounted, and timed from the
    /// moment it goes on screen. `blocks` is the number of (user message,
    /// markdown answer, tool card) triples, so a transcript is 3× that plus the
    /// header — 60 blocks is the ~180-item session the field report came from.
    func testFirstLayoutCostByTranscriptSize() {
        for blocks in [5, 20, 60, 120] {
            let sessionId = "layout-cost-\(blocks)"
            let session = makeSession()
            let conversation = session.conversation(sessionId)
            preload(conversation, blocks: blocks)

            let host = UIHostingController(rootView: NavigationStack {
                ConversationView(session: session, sessionId: sessionId, initiallyAtBottom: true)
            })
            let window = makeWindow()
            window.rootViewController = host

            // The measurement: everything the first frame has to do, timed
            // synchronously. `layoutIfNeeded` drains the SwiftUI transaction the
            // way the render server would.
            let mountStart = CACurrentMediaTime()
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            let firstLayoutMs = (CACurrentMediaTime() - mountStart) * 1000

            // Then the tail: onAppear's scrollTo, `.task`s, and whatever
            // relayout they provoke. Sampled as main-run-loop stalls, because a
            // stall is what the watchdog kills for.
            let meter = Meter()
            meter.start()
            let settleStart = CACurrentMediaTime()
            pump(seconds: 4.0)
            meter.stop()
            let settleMs = (CACurrentMediaTime() - settleStart) * 1000

            let textViews = Self.textViews(in: Self.census(host.view))

            emit(String(
                format: "[LAYOUT] firstLayout blocks=%d items=%d firstLayoutMs=%.1f settleWindowMs=%.0f "
                    + "maxGapMs=%.1f p95GapMs=%.1f over100=%d over250=%d over1000=%d uiTextViews=%d",
                blocks, conversation.items.count, firstLayoutMs, settleMs,
                meter.maxGapMs, meter.p95GapMs, meter.gapsOver(0.100), meter.gapsOver(0.250),
                meter.gapsOver(1.000), textViews
            ))

            teardown(window)
        }
    }


    // MARK: 3 — the composer, against how much is typed into it

    /// `TextField(text:axis:.vertical)` is UIKit's UITextView under a SwiftUI
    /// coat, and `TextViewAdaptor._overrideSizeThatFits` — the frame two of the
    /// four crash reports were sampled inside — is how SwiftUI asks it how tall
    /// it wants to be. `UITextView._intrinsicSizeWithinSize:` answers by laying
    /// the *whole* string out in TextKit 2, not the six lines `lineLimit(1...6)`
    /// will actually show. If that is the freeze, cost grows with the text in
    /// the field and nothing else does.
    ///
    /// The field is the real construct from `Composer`: same axis, same line
    /// limit, same surrounding HStack and padding.
    func testComposerCostByTypedLength() {
        for bytes in [0, 1_000, 10_000, 50_000, 200_000] {
            let seed = String(repeating: "the agent reads the file and rewrites what it found. ", count: max(1, bytes / 53))
            let text = bytes == 0 ? "" : String(seed.prefix(bytes))
            let box = TextBox(text: text)

            let window = makeWindow()
            let host = UIHostingController(rootView: ComposerShape(box: box))
            window.rootViewController = host
            window.makeKeyAndVisible()

            let started = CACurrentMediaTime()
            host.view.layoutIfNeeded()
            let firstMs = (CACurrentMediaTime() - started) * 1000

            // A relayout is what a keystroke, a placeholder change, or any
            // parent state change costs — the steady-state price, not the
            // one-off.
            var relayoutMs = 0.0
            for _ in 0..<5 {
                host.view.setNeedsLayout()
                let again = CACurrentMediaTime()
                host.view.layoutIfNeeded()
                relayoutMs += (CACurrentMediaTime() - again) * 1000
            }
            relayoutMs /= 5

            // And what a single delivered character costs, which is the thing
            // a person actually feels.
            box.text += "x"
            let typed = CACurrentMediaTime()
            pump(seconds: 0.35)
            host.view.layoutIfNeeded()
            let keystrokeMs = (CACurrentMediaTime() - typed) * 1000

            emit(String(
                format: "[LAYOUT] composer bytes=%d firstLayoutMs=%.1f relayoutMs=%.1f keystrokeWindowMs=%.1f uiTextViews=%d",
                text.utf8.count, firstMs, relayoutMs, keystrokeMs,
                Self.textViews(in: Self.census(host.view))
            ))
            teardown(window)
        }
    }


    // MARK: 4 — does a scrolling text view escape the cost?

    /// The candidate fix, measured on the same ladder as test 3 before any of
    /// it goes near the app.
    ///
    /// A UITextView that scrolls lays text out by viewport, so the whole string
    /// is never measured — but only if nothing asks it for an intrinsic size.
    /// The height therefore comes from a measurement that is skipped once the
    /// text is long enough that the answer is certainly "the maximum", which is
    /// true from a few hundred characters on.
    func testScrollingFieldCostByTypedLength() {
        for bytes in [0, 1_000, 10_000, 50_000, 200_000] {
            let seed = String(repeating: "the agent reads the file and rewrites what it found. ", count: max(1, bytes / 53))
            let text = bytes == 0 ? "" : String(seed.prefix(bytes))
            let box = TextBox(text: text)

            let window = makeWindow()
            let host = UIHostingController(rootView: ScrollingComposerShape(box: box))
            window.rootViewController = host
            window.makeKeyAndVisible()

            let started = CACurrentMediaTime()
            host.view.layoutIfNeeded()
            let firstMs = (CACurrentMediaTime() - started) * 1000

            box.text += "x"
            let typed = CACurrentMediaTime()
            pump(seconds: 0.35)
            host.view.layoutIfNeeded()
            let keystrokeMs = (CACurrentMediaTime() - typed) * 1000

            emit(String(
                format: "[LAYOUT] scrollingField bytes=%d firstLayoutMs=%.1f keystrokeWindowMs=%.1f",
                text.utf8.count, firstMs, keystrokeMs
            ))
            teardown(window)
        }
    }


    // MARK: 5 — where the remaining first-layout cost lives

    /// `GrowingField` removed the per-keystroke cost but not the one-off, so
    /// this splits the one-off into its parts on a bare UITextView: handing it
    /// the string, letting Auto Layout run over it, and asking it to draw.
    func testTextViewIngestCost() {
        for bytes in [10_000, 50_000, 200_000] {
            let seed = String(repeating: "the agent reads the file and rewrites what it found. ", count: max(1, bytes / 53))
            let text = String(seed.prefix(bytes))

            let plainView = UITextView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
            plainView.isScrollEnabled = true
            plainView.font = .systemFont(ofSize: 16)
            var t = CACurrentMediaTime()
            plainView.text = text
            let assignScrollMs = (CACurrentMediaTime() - t) * 1000
            t = CACurrentMediaTime()
            plainView.layoutIfNeeded()
            let layoutScrollMs = (CACurrentMediaTime() - t) * 1000

            let noScroll = UITextView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
            noScroll.isScrollEnabled = false
            noScroll.font = .systemFont(ofSize: 16)
            t = CACurrentMediaTime()
            noScroll.text = text
            let assignNoScrollMs = (CACurrentMediaTime() - t) * 1000
            t = CACurrentMediaTime()
            _ = noScroll.intrinsicContentSize
            let intrinsicMs = (CACurrentMediaTime() - t) * 1000

            // With a placeholder label constrained inside, the way GrowingField
            // does it.
            let withLabel = UITextView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
            withLabel.isScrollEnabled = true
            withLabel.font = .systemFont(ofSize: 16)
            let label = UILabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            withLabel.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: withLabel.leadingAnchor),
                label.topAnchor.constraint(equalTo: withLabel.topAnchor),
            ])
            withLabel.text = text
            t = CACurrentMediaTime()
            withLabel.layoutIfNeeded()
            let labelLayoutMs = (CACurrentMediaTime() - t) * 1000

            emit(String(
                format: "[LAYOUT] ingest bytes=%d assignScrollMs=%.1f layoutScrollMs=%.1f "
                    + "assignNoScrollMs=%.1f intrinsicMs=%.1f withLabelLayoutMs=%.1f",
                text.utf8.count, assignScrollMs, layoutScrollMs,
                assignNoScrollMs, intrinsicMs, labelLayoutMs
            ))
        }
    }


    // MARK: 6 — is the residue in the measurement or in SwiftUI's plumbing?

    /// `GrowingField` still costs seconds on its *first* layout of a very long
    /// string even though the primitives it is built from cost milliseconds
    /// (test 5). Two candidates: the height measurement it does under the
    /// ceiling, or something in SwiftUI's representable plumbing that measures
    /// the text view regardless of what `sizeThatFits` answers.
    ///
    /// `FixedField` answers a constant and does nothing else. If it is fast the
    /// residue is ours; if it is slow the residue is SwiftUI's and the shape of
    /// the fix has to change.
    func testFixedHeightFieldCost() {
        for bytes in [10_000, 50_000, 200_000] {
            let seed = String(repeating: "the agent reads the file and rewrites what it found. ", count: max(1, bytes / 53))
            let text = String(seed.prefix(bytes))
            let window = makeWindow()
            let host = UIHostingController(rootView: HStack(alignment: .bottom, spacing: 6) {
                Image(systemName: "photo.on.rectangle").frame(width: 32, height: 34)
                FixedField(text: .constant(text))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                Image(systemName: "arrow.up").frame(width: 34, height: 34)
            }.padding(.horizontal, 16))
            window.rootViewController = host
            window.makeKeyAndVisible()

            let started = CACurrentMediaTime()
            host.view.layoutIfNeeded()
            let firstMs = (CACurrentMediaTime() - started) * 1000

            emit(String(format: "[LAYOUT] fixedField bytes=%d firstLayoutMs=%.1f sizeThatFitsCalls=%d",
                        text.utf8.count, firstMs, FixedField.calls))
            FixedField.calls = 0
            teardown(window)
        }
    }

    // MARK: - Plumbing

    private func makeSession() -> MachineSession {
        let bundle = PairingBundle(
            relay: "https://relay.invalid", direct: nil, device: "device-1",
            key: "", token: "", name: "Test Mac"
        )
        let suite = UserDefaults(suiteName: "layout-cost-\(UUID().uuidString)")!
        return MachineSession(
            machine: PairedMachine(bundle: bundle),
            identity: .generate(),
            deviceName: "Test iPhone",
            clientVersion: "rowel-tests/1",
            pairingToken: nil,
            notifier: Notifier(center: nil),
            defaults: suite,
            transport: QuietTransport()
        )
    }

    private func preload(_ conversation: Conversation, blocks: Int) {
        var seq = 1
        func apply(_ type: String, _ data: JSONValue) {
            conversation.apply(event: .object([
                "type": .string(type),
                "seq": .number(Double(seq)),
                "time": .number(1_700_000_000_000 + Double(seq)),
                "data": data,
            ]), view: nil)
            seq += 1
        }
        for block in 0..<blocks {
            apply("user/message", .object([
                "id": .string("u\(block)"),
                "source": .object(["kind": .string("user")]),
                "content": .array([
                    .object(["type": .string("text"), "text": .string("Please do step \(block): " + Self.prose(10, seed: block))]),
                ]),
            ]))
            apply("assistant/message", .object([
                "turn": .number(Double(block)), "step": .number(0),
                "message": .object([
                    "content": .array([
                        .object(["type": .string("text"), "text": .string(Self.markdownBody(block))]),
                    ]),
                ]),
            ]))
            let callId = "call-\(block)"
            apply("tool/call", .object([
                "callId": .string(callId), "name": .string("Bash"),
                "arguments": .string("{\"command\":\"make step\(block)\"}"),
            ]))
            apply("tool/result", .object([
                "message": .object([
                    "source": .object(["callId": .string(callId)]),
                    "content": .array([
                        .object([
                            "toolCallId": .string(callId),
                            "content": .array([
                                .object(["type": .string("text"), "text": .string("step \(block) ok\n" + Self.prose(20, seed: block + 500))]),
                            ]),
                        ]),
                    ]),
                ]),
            ]))
        }
    }

    private func makeWindow() -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene.map { UIWindow(windowScene: $0) }
            ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    }

    private func mountRaw<V: View>(_ view: V) -> UIWindow {
        let window = makeWindow()
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        window.rootViewController?.view.layoutIfNeeded()
        pump(seconds: 0.6)
        return window
    }

    private func teardown(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    private func pump(seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    private func emit(_ line: String) {
        print(line)
        NSLog("%@", line)
        guard let data = (line + "\n").data(using: .utf8) else { return }
        let path = "/tmp/rowel-layout-results.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }

    // MARK: - View census

    /// Class-name histogram of a UIKit subtree. Cheaper to read than a full
    /// hierarchy dump and it answers the only question here: how many of each.
    private static func census(_ root: UIView) -> [String: Int] {
        var counts: [String: Int] = [:]
        var stack = [root]
        while let view = stack.popLast() {
            counts[String(describing: type(of: view)), default: 0] += 1
            stack.append(contentsOf: view.subviews)
        }
        return counts
    }

    private static func textViews(in counts: [String: Int]) -> Int {
        counts.filter { $0.key.contains("TextView") }.values.reduce(0, +)
    }

    private static func describe(_ counts: [String: Int]) -> String {
        counts.sorted { ($0.value, $0.key) > ($1.value, $1.key) }
            .prefix(8).map { "\($0.key)×\($0.value)" }.joined(separator: " ")
    }

    // MARK: - Corpus

    private static let words = [
        "the", "agent", "reads", "the", "file", "and", "rewrites", "what", "it",
        "found", "then", "runs", "the", "tests", "again", "until", "they", "pass",
        "while", "noting", "every", "change", "in", "a", "long", "careful", "list",
    ]

    static func prose(_ count: Int, seed: Int) -> String {
        (0..<count).map { words[(seed &+ $0 &* 7) % words.count] }.joined(separator: " ")
    }

    static func markdownBody(_ index: Int) -> String {
        var made = "### Step \(index): what changed\n\n"
        made += prose(60, seed: index) + "\n\n"
        made += "- " + prose(8, seed: index + 1) + "\n"
        made += "- " + prose(9, seed: index + 2) + "\n\n"
        made += "```swift\nfunc step\(index)() { print(\(index)) }\n```\n\n"
        made += prose(50, seed: index + 4)
        return made
    }
}

// MARK: - Main run loop stall probe

/// Records gaps between display-link ticks. A gap is the main thread not
/// turning, which is the same condition the watchdog kills for.
@MainActor
private final class Meter: NSObject {
    private var link: CADisplayLink?
    private var stamps: [CFTimeInterval] = []

    func start() {
        stamps.removeAll(keepingCapacity: true)
        let made = CADisplayLink(target: self, selector: #selector(tick(_:)))
        made.add(to: .main, forMode: .common)
        link = made
    }

    func stop() { link?.invalidate(); link = nil }

    @objc private func tick(_ sender: CADisplayLink) { stamps.append(sender.timestamp) }

    private var gaps: [Double] {
        guard stamps.count >= 2 else { return [] }
        return (1..<stamps.count).map { stamps[$0] - stamps[$0 - 1] }
    }

    var maxGapMs: Double { (gaps.max() ?? 0) * 1000 }

    var p95GapMs: Double {
        let sorted = gaps.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))] * 1000
    }

    func gapsOver(_ seconds: Double) -> Int { gaps.filter { $0 > seconds }.count }
}

// MARK: - The composer's own shape, isolated

/// Mutable text the test can drive from outside, since `Composer` keeps its
/// own in `@State` where a test cannot reach it.
@MainActor
private final class TextBox: ObservableObject {
    @Published var text: String
    init(text: String) { self.text = text }
}

/// `Composer`'s field and the layout immediately around it, and nothing else —
/// so a number here is the field's cost and not the app's.
private struct ComposerShape: View {
    @ObservedObject var box: TextBox

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Image(systemName: "photo.on.rectangle").frame(width: 32, height: 34)
            TextField("Message", text: $box.text, axis: .vertical)
                .font(.system(size: 16))
                .lineLimit(1...6)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.gray.opacity(0.2), in: RoundedRectangle(cornerRadius: 19))
            Image(systemName: "arrow.up").frame(width: 34, height: 34)
        }
        .padding(.horizontal, 16)
    }
}

/// The candidate: `GrowingField` in the same surroundings as `ComposerShape`,
/// so the two ladders differ only in the field.
private struct ScrollingComposerShape: View {
    @ObservedObject var box: TextBox

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Image(systemName: "photo.on.rectangle").frame(width: 32, height: 34)
            GrowingField(text: $box.text, focused: .constant(false), maxLines: 6)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.gray.opacity(0.2), in: RoundedRectangle(cornerRadius: 19))
            Image(systemName: "arrow.up").frame(width: 34, height: 34)
        }
        .padding(.horizontal, 16)
    }
}

/// A scrolling UITextView that answers a constant height and measures nothing.
private struct FixedField: UIViewRepresentable {
    @Binding var text: String
    nonisolated(unsafe) static var calls = 0

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isScrollEnabled = true
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.font = .systemFont(ofSize: 16)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if context.coordinator.last != text {
            view.text = text
            context.coordinator.last = text
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        Self.calls += 1
        return CGSize(width: proposal.width ?? 200, height: 120)
    }

    func makeCoordinator() -> Box { Box() }
    final class Box { var last = "" }
}
