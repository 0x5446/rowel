/// Does a tall question card fit on the screen?
///
/// Field report: "the blue Send button won't take a tap — it is too close to
/// the bottom — and dragging to see the top does nothing either."
///
/// The screenshot that came with it says what happened: the card's last option
/// is on screen, the Send button below it is cut off by the bottom edge — the
/// home indicator is drawn *on top of it* — and the first two options are
/// missing under the navigation bar. Nothing scrolls, because nothing in the
/// footer band is a scroll view.
///
/// The footer is a plain `VStack`: an approval card, a question card, the queue
/// strip, the composer, the stat strip. Every one of those except the composer
/// grows with its content, and the question card grows with *every* question
/// the agent asked — three questions with ten options between them is a normal
/// request, and it is taller than the screen. The column then overflows in both
/// directions: the top of it slides under the navigation bar, the composer and
/// the Send button are pushed past the bottom edge into the strip iOS reserves
/// for the home gesture, and a tap there is the system's, not the button's.
///
/// The experiment mounts the real `ConversationView` in a real `UIWindow`, hands
/// it a question exactly as the tunnel would, renders the window, and looks for
/// the Send button in the pixels — a full-width run of `Palette.accent`. Two
/// conditions on the same rig: a card that fits, and the card from the report.
///
/// The assertion is the bug, stated as a number: no full-width accent band may
/// be drawn inside the bottom safe-area inset, which is where a tap stops being
/// the app's.

import XCTest
import SwiftUI
import UIKit
@testable import Rowel

// MARK: - Transport

/// Answers every harness call with an empty object, so the reads the view fires
/// on open come back immediately and the transcript under test is the only
/// content that matters.
private actor QuietTransport: HarnessTransport {
    func call(_ method: String, _ payload: JSONValue) async throws -> JSONValue { .emptyObject }
    func respond(rpcId: String, value: JSONValue) async throws -> JSONValue { .emptyObject }
}

// MARK: - Pixels

/// What a rendered frame says about where the accent-coloured buttons landed.
struct AccentBands {
    var rows: [Int] = []
    var width: Int = 0

    /// A row counts as a button when the accent covers nearly the whole width.
    ///
    /// Two thresholds, both load-bearing. Width tells a button from a message
    /// bubble: a bubble is right-aligned and two thirds of the width at most,
    /// and the composer's own send button is a 34-point circle. Saturation tells
    /// a button from the card's own border, which is `Palette.accent` at 45%
    /// over white — nearly the same hue, a fifth of the ink, and the one thing
    /// that would otherwise be mistaken for the button it surrounds.
    static let widthFraction = 0.85
    static let solidRed = 110

    static func measure(_ image: UIImage) -> AccentBands {
        guard let cg = image.cgImage else { return AccentBands() }
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(
            data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return AccentBands() }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var bands = AccentBands(width: w)
        // Counted over every second pixel, so the bar is half the width.
        let threshold = Int(Double(w) * widthFraction / 2)
        for y in 0..<h {
            var count = 0
            for x in stride(from: 0, to: w, by: 2) {
                let i = (y * w + x) * 4
                let r = Int(data[i]), g = Int(data[i + 1]), b = Int(data[i + 2])
                if b > 180, b - r > 60, b - g > 40, r < solidRed { count += 1 }
            }
            if count > threshold { bands.rows.append(y) }
        }
        return bands
    }

    /// The lowest row of the lowest band, in points.
    func lowestRow(scale: CGFloat) -> CGFloat? {
        rows.last.map { CGFloat($0) / scale }
    }

    /// How tall the tallest band is, in points — a button is a band, a stray
    /// anti-aliased edge is not.
    func tallestBand(scale: CGFloat) -> CGFloat {
        var best = 0, run = 0, previous = -10
        for row in rows {
            run = row == previous + 1 ? run + 1 : 1
            previous = row
            best = max(best, run)
        }
        return CGFloat(best) / scale
    }
}

// MARK: - The experiment

@MainActor
final class InterruptLayoutTests: XCTestCase {
    private let sessionId = "session-interrupt-layout"

    /// The card from the report: three questions, ten options, every option
    /// carrying the sentence that explains it.
    private func reportedQuestions() -> JSONValue {
        func option(_ label: String, _ description: String) -> JSONValue {
            .object(["label": .string(label), "description": .string(description)])
        }
        return .array([
            .object([
                "id": .string("q1"),
                "header": .string("确认症状"),
                "question": .string("在 Rowel App 里发完消息后，是什么状态？"),
                "options": .array([
                    option("整个界面冻结：不能滚动、点按没反应", "主线程被占死，符合 CPU/布局饿死"),
                    option("界面还能动，但消息一直不回、一直转圈", "更像连接/请求问题，不是渲染"),
                    option("白屏或直接闪退回桌面", "更像内存被杀（jetsam）或崩溃"),
                    option("不确定，反正只能杀掉重开", "我按最坏情况一起查"),
                ]),
            ]),
            .object([
                "id": .string("q2"),
                "header": .string("触发范围"),
                "question": .string("是所有会话都这样，还是只有那种很长的会话？"),
                "options": .array([
                    option("只有长会话/输出很快时会卡", "指向渲染量随会话增长的问题"),
                    option("任何会话，哪怕刚新建的也会卡", "指向发送路径本身，和会话大小无关"),
                    option("没注意过区别", "两边都查"),
                ]),
            ]),
            .object([
                "id": .string("q3"),
                "header": .string("现场证据"),
                "question": .string("App 的 Diagnostics 页面里有没有「Hangs and crashes」记录？"),
                "options": .array([
                    option("有记录，我分享给你", "MetricKit 抓的主线程调用栈，能直接定位卡在哪一行"),
                    option("有记录，但不知道怎么看/怎么给", "我告诉你在哪一步点分享"),
                    option("没有记录 / App 里找不到这个页面", "那就靠模拟器复现和代码分析"),
                ]),
            ]),
        ])
    }

    /// A card that plainly fits: one question, two options.
    private func smallQuestions() -> JSONValue {
        .array([
            .object([
                "id": .string("q1"),
                "header": .string("Confirm"),
                "question": .string("Run the migration on the staging database?"),
                "options": .array([
                    .object(["label": .string("Yes"), "description": .string("It is a copy.")]),
                    .object(["label": .string("Not now"), "description": .string("I will look first.")]),
                ]),
            ]),
        ])
    }

    func testASmallCardKeepsItsSendButtonOffTheHomeIndicator() {
        run(questions: smallQuestions(), condition: "small")
    }

    func testBTheReportedCardKeepsItsSendButtonOffTheHomeIndicator() {
        run(questions: reportedQuestions(), condition: "reported")
    }

    // MARK: Runner

    private func run(questions: JSONValue, condition: String) {
        let session = makeSession()
        let conversation = session.conversation(sessionId)
        seed(conversation)
        session.receiveForTesting(.event(EventFrame(seq: 1, stream: .mux, frame: .object([
            "rpcId": .string("rpc-1"),
            "type": .string("question/requested"),
            "sessionId": .string(sessionId),
            "questions": questions,
        ]))))
        XCTAssertNotNil(session.questions[sessionId], "the card under test must be on screen")

        let window = mount(session: session)
        pump(seconds: 1.2)

        guard let image = snapshot(window) else {
            return XCTFail("the window did not render; the measurement is void")
        }
        save(image, as: condition)

        let scale = window.traitCollection.displayScale
        let inset = window.safeAreaInsets.bottom
        let bands = AccentBands.measure(image)
        let floor = window.bounds.height - inset
        let lowest = bands.lowestRow(scale: scale)
        let tallest = bands.tallestBand(scale: scale)

        let line = String(
            format: "[LAYOUT] cond=%@ window=%.0fx%.0f insetBottom=%.0f imageW=%d lowestAccentBandRow=%@ tallestAccentBandPt=%.0f accentRows=%d floor=%.0f",
            condition, window.bounds.width, window.bounds.height, inset,
            bands.width, lowest.map { String(format: "%.0f", $0) } ?? "none", tallest, bands.rows.count, floor
        )
        print(line)
        NSLog("%@", line)

        // The button has to be on screen at all — a card that answers itself by
        // scrolling its own Send button out of view would otherwise pass the
        // check below for the wrong reason. The floor on the run's height is
        // what says "button" rather than "hairline": a rounded button loses its
        // corners to the width threshold, so only its straight middle is left.
        XCTAssertNotNil(lowest, "the card's Send button was not drawn anywhere on screen")
        XCTAssertGreaterThan(tallest, 8, "no full-width button was drawn; the detector found only stray accent")
        XCTAssertLessThan(
            lowest ?? .greatestFiniteMagnitude, floor,
            "the Send button is drawn at or below the home-indicator inset (\(lowest ?? -1) vs \(floor)); a tap there belongs to the system"
        )
    }

    // MARK: Fixtures

    private func makeSession() -> MachineSession {
        let bundle = PairingBundle(
            relay: "https://relay.invalid", direct: nil, device: "device-1",
            key: "", token: "", name: "Test Mac"
        )
        return MachineSession(
            machine: PairedMachine(bundle: bundle),
            identity: .generate(),
            deviceName: "Test iPhone",
            clientVersion: "rowel-tests/1",
            pairingToken: nil,
            notifier: Notifier(center: nil),
            defaults: UserDefaults(suiteName: "interrupt-layout-\(UUID().uuidString)")!,
            transport: QuietTransport()
        )
    }

    /// A short conversation, so the transcript is a real sibling of the footer
    /// rather than an empty box that would flatter the layout.
    private func seed(_ conversation: Conversation) {
        var seq = 100
        func apply(_ type: String, _ data: JSONValue) {
            conversation.apply(event: .object([
                "type": .string(type),
                "seq": .number(Double(seq)),
                "time": .number(1_700_000_000_000 + Double(seq)),
                "data": data,
            ]), view: nil)
            seq += 1
        }
        for turn in 0..<3 {
            apply("user/message", .object([
                "id": .string("u\(turn)"),
                "source": .object(["kind": .string("user")]),
                "content": .array([
                    .object(["type": .string("text"), "text": .string("Question \(turn): what does the harness do here?")]),
                ]),
            ]))
            apply("assistant/message", .object([
                "turn": .number(Double(turn)),
                "step": .number(0),
                "message": .object([
                    "content": .array([
                        .object(["type": .string("text"), "text": .string(
                            "It folds the event log. Paragraph \(turn) explains it well enough to take two lines on a phone."
                        )]),
                    ]),
                ]),
            ]))
        }
        apply("turn/end", .emptyObject)
    }

    private func mount(session: MachineSession) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        let window: UIWindow
        if let scene {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        }
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            ConversationView(session: session, sessionId: sessionId)
        })
        window.makeKeyAndVisible()
        return window
    }

    private func snapshot(_ window: UIWindow) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        return renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    /// The simulator writes straight to the host's /tmp, so the frames survive
    /// however much noise xcodebuild wraps around stdout.
    private func save(_ image: UIImage, as condition: String) {
        guard let data = image.pngData() else { return }
        try? data.write(to: URL(fileURLWithPath: "/tmp/rowel-interrupt-\(condition).png"))
    }

    private func pump(seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }
}
