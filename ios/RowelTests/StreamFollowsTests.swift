/// Does a streaming answer keep the end of the transcript on screen?
///
/// Two mechanisms have claimed this job at different times: the scroll view's
/// own bottom anchor (`.defaultScrollAnchor`), which is part of layout, and an
/// explicit `scrollTo` on every change that grows the content, which makes the
/// lazy stack lay itself out to the end to find the anchor it is being sent to.
/// The second one is what the starvation rig caught — 42% of all frames at the
/// rate this harness streams, and a TestFlight build killed by iOS inside
/// `AttributeGraph` for it.
///
/// So the behaviour is stated here, once, where either mechanism can satisfy it:
/// while following, the end of the answer is on screen; while reading back, the
/// text arriving below does not drag the reader down. A mechanism that can be
/// deleted without failing these is a mechanism that was not doing the job.
///
/// The transcript is mounted in a real `UIWindow` and read through its own
/// `UIScrollView`, because "followed the stream" is a fact about a scroll
/// offset, and no amount of view state makes it true.

import XCTest
import SwiftUI
import UIKit
@testable import Rowel

// MARK: - Transport

/// Answers every harness call with an empty object, so the reads the view fires
/// on open come back immediately and the transcript is the only content.
private actor QuietTransport: HarnessTransport {
    func call(_ method: String, _ payload: JSONValue) async throws -> JSONValue { .emptyObject }
    func respond(rpcId: String, value: JSONValue) async throws -> JSONValue { .emptyObject }
}

// MARK: - The experiment

@MainActor
final class StreamFollowsTests: XCTestCase {
    private let sessionId = "session-stream-follows"
    /// How close to the end counts as following, in points.
    ///
    /// Not zero, and the number is a contract rather than a fudge. Following a
    /// stream is capped at one pull every 100 ms (`ConversationView.followInterval`),
    /// so a snapshot taken mid-stream can have the newest delta still below the
    /// fold — and the end of the turn forces the last pull, which is why the
    /// person never sees it. Two lines of 15-point text plus the gaps, and no
    /// more: this test caught 234 points with the follow gone entirely, so the
    /// difference between "following" and "not" is well outside it.
    private let endTolerance: CGFloat = 100

    func testWhileFollowingTheEndIsOnScreen() {
        let (_, conversation) = mount(following: true)
        guard let scroll = transcript() else { return XCTFail("no transcript scroll view; the measurement is void") }
        XCTAssertTrue(atEnd(scroll), "a conversation opened while following should open at its end")
        XCTAssertTrue(scroll.contentSize.height > scroll.bounds.height + 40, "the transcript must be long enough to scroll")
        _ = conversation

        stream(into: conversation, deltas: 12)

        XCTAssertTrue(
            atEnd(scroll),
            "the streamed answer ended \(scroll.contentSize.height - scroll.bounds.height - scroll.contentOffset.y) pt below the fold"
        )
    }

    func testReadingBackIsNotDraggedDownByTheStream() {
        let (session, conversation) = mount(following: false)
        guard let scroll = transcript() else { return XCTFail("no transcript scroll view; the measurement is void") }
        _ = session
        let before = scroll.contentOffset.y

        stream(into: conversation, deltas: 12)

        XCTAssertLessThan(
            scroll.contentOffset.y, scroll.contentSize.height - scroll.bounds.height - 40,
            "a reader who scrolled back was pulled to the end by text arriving below them"
        )
        XCTAssertEqual(scroll.contentOffset.y, before, accuracy: 40,
                       "the fold moved while the reader was reading back")
    }

    // MARK: Fixtures

    private var window: UIWindow?

    private func mount(following: Bool) -> (MachineSession, Conversation) {
        let bundle = PairingBundle(
            relay: "https://relay.invalid", direct: nil, device: "device-1",
            key: "", token: "", name: "Test Mac"
        )
        let session = MachineSession(
            machine: PairedMachine(bundle: bundle),
            identity: .generate(),
            deviceName: "Test iPhone",
            clientVersion: "rowel-tests/1",
            pairingToken: nil,
            notifier: Notifier(center: nil),
            defaults: UserDefaults(suiteName: "stream-follows-\(UUID().uuidString)")!,
            transport: QuietTransport()
        )
        let conversation = session.conversation(sessionId)
        seed(conversation)

        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let made = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        made.rootViewController = UIHostingController(rootView: NavigationStack {
            ConversationView(session: session, sessionId: sessionId, initiallyAtBottom: following)
        })
        made.makeKeyAndVisible()
        window = made
        // The first layout, the open anchor, and the reads the view fires on
        // appear. Long enough that anything still settling has settled.
        pump(seconds: 2.5)
        return (session, conversation)
    }

    /// A conversation long enough to scroll, ending in a turn that is still
    /// being written — the state a person is in when they have just sent
    /// something and the answer is arriving.
    private func seed(_ conversation: Conversation) {
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
        for turn in 0..<24 {
            apply("user/message", .object([
                "id": .string("u\(turn)"),
                "source": .object(["kind": .string("user")]),
                "content": .array([
                    .object(["type": .string("text"), "text": .string("Turn \(turn): what does the harness do with this?")]),
                ]),
            ]))
            apply("assistant/message", .object([
                "turn": .number(Double(turn)),
                "step": .number(0),
                "message": .object([
                    "content": .array([
                        .object(["type": .string("text"), "text": .string(
                            "It folds the event log, then draws what the fold says. Paragraph \(turn) is long enough to take two lines on a phone, which is what makes the transcript scroll."
                        )]),
                    ]),
                ]),
            ]))
        }
        apply("turn/start", .emptyObject)
        apply("assistant/chunk", .object([
            "turn": .number(99), "step": .number(0),
            "chunk": .object(["type": .string("text-delta"), "text": .string("The answer is arriving")]),
        ]))
    }

    /// Grow the open bubble the way the tunnel does, a few deltas at a time.
    private func stream(into conversation: Conversation, deltas: Int) {
        for index in 0..<deltas {
            conversation.apply(event: .object([
                "type": .string("assistant/chunk"),
                "seq": .number(Double(1_000 + index)),
                "time": .number(1_700_000_100_000 + Double(index)),
                "data": .object([
                    "turn": .number(99), "step": .number(0),
                    "chunk": .object([
                        "type": .string("text-delta"),
                        "text": .string(" and one more line of the answer, number \(index)."),
                    ]),
                ]),
            ]), view: nil)
            pump(seconds: 0.12)
        }
        // A last moment for the layout and any follow to land.
        pump(seconds: 1.0)
    }

    // MARK: Reading the screen

    private func transcript() -> UIScrollView? {
        guard let window else { return nil }
        let all = StreamFollowsTests.scrollViews(in: window)
        // The transcript is the tallest content in the window; a code block's
        // sideways scroller and the interrupt band are both shorter than their
        // own viewport.
        return all.filter { $0.contentSize.height > $0.bounds.height }.max { $0.contentSize.height < $1.contentSize.height }
    }

    private static func scrollViews(in view: UIView) -> [UIScrollView] {
        var found: [UIScrollView] = []
        if let scroll = view as? UIScrollView { found.append(scroll) }
        for sub in view.subviews { found.append(contentsOf: scrollViews(in: sub)) }
        return found
    }

    private func atEnd(_ scroll: UIScrollView) -> Bool {
        scroll.contentOffset.y + scroll.bounds.height >= scroll.contentSize.height - endTolerance
    }

    private func pump(seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }
}
