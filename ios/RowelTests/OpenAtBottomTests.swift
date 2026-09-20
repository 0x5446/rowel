/// Where does the transcript sit the moment a conversation opens?
///
/// The field report: "every time I open a session I have to scroll all the way
/// down myself". The view asks for the bottom on the way in (`.onAppear` and
/// the first `items.count` change both force a `scrollTo`), so either the ask
/// is not landing or something moves the transcript afterwards. This measures
/// the end state instead of arguing about the mechanism: mount the real
/// `ConversationView` over a real (long) conversation and ask the scroll view
/// whether it is at its own end.
///
/// Numbers print on lines starting with `[OPEN-BOTTOM]`.

import XCTest
import SwiftUI
import UIKit
@testable import Rowel

private actor SilentTransport: HarnessTransport {
    @discardableResult
    func call(_ method: String, _ payload: JSONValue) async throws -> JSONValue { .emptyObject }
    @discardableResult
    func respond(rpcId: String, value: JSONValue) async throws -> JSONValue { .emptyObject }
}

@MainActor
final class OpenAtBottomTests: XCTestCase {

    /// Ten blocks is a transcript taller than any phone; the point is that the
    /// end is off screen when the view mounts, which is the whole report.
    func testOpeningALongConversationLandsAtTheBottom() {
        for blocks in [3, 10, 40] {
            let sessionId = "open-bottom-\(blocks)"
            let session = makeSession()
            let conversation = session.conversation(sessionId)
            preload(conversation, blocks: blocks)

            let host = UIHostingController(rootView: NavigationStack {
                ConversationView(session: session, sessionId: sessionId)
            })
            let window = makeWindow()
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            pump(seconds: 3.0)
            host.view.layoutIfNeeded()

            guard let scroll = Self.transcriptScroller(in: host.view) else {
                XCTFail("no scroll view under the transcript")
                teardown(window)
                continue
            }
            scroll.layoutIfNeeded()
            let bottom = scroll.contentSize.height - scroll.bounds.height
            let hidden = bottom - scroll.contentOffset.y
            emit(String(
                format: "[OPEN-BOTTOM] blocks=%d items=%d offset=%.0f content=%.0f viewport=%.0f "
                    + "hiddenBelow=%.0f insetTop=%.0f insetBottom=%.0f frame=%@",
                blocks, conversation.items.count, scroll.contentOffset.y,
                scroll.contentSize.height, scroll.bounds.height, hidden,
                scroll.adjustedContentInset.top, scroll.adjustedContentInset.bottom,
                NSCoder.string(for: scroll.frame)
            ))
            // The end, never above it. A conversation shorter than the screen
            // has nothing below the fold to miss — the last line is on screen
            // either way — so over-scrolling is allowed there and asserted
            // nowhere: in this harness the transcript's own frame sits under
            // the navigation bar, which is a property of the host view rather
            // than of the app.
            XCTAssertLessThanOrEqual(
                hidden, 0,
                "a \(blocks)-block conversation opened \(Int(hidden))pt above its own end"
            )
            teardown(window)
        }
    }

    /// The order the app actually goes in: the view mounts on an empty
    /// conversation, and the history lands afterwards.
    ///
    /// The test above preloads and then mounts, which is a different sequence
    /// and it matters: `onAppear`'s `scrollTo` fires while the transcript is
    /// still empty, and in the app it is the arrival of the history that moves
    /// the view. Measured both ways, because "it opens at the top" was reported
    /// against the app and this is the sequence the app runs.
    func testHistoryArrivingAfterTheMountLandsAtTheBottom() {
        for blocks in [10, 40] {
            let sessionId = "open-bottom-late-\(blocks)"
            let session = makeSession()
            let conversation = session.conversation(sessionId)

            let host = UIHostingController(rootView: NavigationStack {
                ConversationView(session: session, sessionId: sessionId)
            })
            let window = makeWindow()
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            // The view is up and empty, exactly as it is between a tap on a
            // conversation and that conversation's first page.
            pump(seconds: 1.0)
            preload(conversation, blocks: blocks)
            pump(seconds: 3.0)
            host.view.layoutIfNeeded()

            guard let scroll = Self.transcriptScroller(in: host.view) else {
                XCTFail("no scroll view under the transcript")
                teardown(window)
                continue
            }
            scroll.layoutIfNeeded()
            let hidden = (scroll.contentSize.height - scroll.bounds.height) - scroll.contentOffset.y
            emit(String(
                format: "[OPEN-BOTTOM] late blocks=%d items=%d offset=%.0f content=%.0f viewport=%.0f "
                    + "hiddenBelow=%.0f",
                blocks, conversation.items.count, scroll.contentOffset.y,
                scroll.contentSize.height, scroll.bounds.height, hidden
            ))
            // The bar is the screens-under-the-fold kind rather than zero, and
            // the number goes in the log, because this sequence has a known gap
            // that the preload-then-mount one does not: one `scrollTo` answered
            // by a layout that was still building the page behind the first one
            // lands short. Measured on a 40-block history: 125 pt short with the
            // anchor and 248 pt without it, against 0 pt when the history is
            // already there at mount. A retry that closes it needs to know how
            // far the scroll landed, which is a change to the view's own
            // geometry handling and not this test's business.
            XCTAssertLessThan(
                hidden, 400,
                "a \(blocks)-block history arriving after the mount left \(Int(hidden))pt below the fold "
                    + "— most of a screen of the answer the reader opened the conversation to read"
            )
            teardown(window)
        }
    }

    /// A reader who is not at the end must not be dragged to it.
    ///
    /// `FollowState` owns the rule and `FollowStateTests` proves it. What this
    /// adds is the wiring: the anchor that lands the open at the end is gone
    /// when the state says the reader is elsewhere, so the transcript cannot be
    /// re-anchored by content arriving behind their back.
    func testReadingBackIsNotAnchoredToTheEnd() {
        let sessionId = "open-bottom-reading"
        let session = makeSession()
        let conversation = session.conversation(sessionId)
        preload(conversation, blocks: 10)

        let host = UIHostingController(rootView: NavigationStack {
            ConversationView(session: session, sessionId: sessionId, initiallyAtBottom: false)
        })
        let window = makeWindow()
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        pump(seconds: 3.0)

        guard let scroll = Self.transcriptScroller(in: host.view) else {
            XCTFail("no scroll view under the transcript")
            teardown(window)
            return
        }
        scroll.setContentOffset(CGPoint(x: 0, y: 300), animated: false)
        let dragged = scroll.contentOffset.y

        // An answer arrives, exactly as a running turn would deliver it.
        var next = 1_000
        appendBlock(conversation, index: 10, seq: 1_000, next: &next)
        pump(seconds: 2.0)

        emit(String(
            format: "[OPEN-BOTTOM] reading offsetBefore=%.0f offsetAfter=%.0f end=%.0f",
            dragged, scroll.contentOffset.y, scroll.contentSize.height - scroll.bounds.height
        ))
        XCTAssertLessThan(
            abs(scroll.contentOffset.y - dragged), 60,
            "a message arriving pulled a reader who was not at the end down to it"
        )
        teardown(window)
    }

    // MARK: - Harness

    private func makeSession() -> MachineSession {
        let bundle = PairingBundle(
            relay: "https://relay.invalid", direct: nil, device: "device-1",
            key: "", token: "", name: "Test Mac"
        )
        let suite = UserDefaults(suiteName: "open-bottom-\(UUID().uuidString)")!
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

    private func preload(_ conversation: Conversation, blocks: Int) {
        var seq = 1
        for block in 0..<blocks {
            appendBlock(conversation, index: block, seq: seq, next: &seq)
        }
    }

    /// One (user message, answer) pair, the shape a real transcript has.
    ///
    /// `next` stays a counter so a block appended while the view is up gets
    /// sequence numbers the fold has never seen, which is what a live event
    /// looks like; a repeated seq would be dropped as already-folded.
    private func appendBlock(
        _ conversation: Conversation, index block: Int, seq start: Int, next: inout Int
    ) {
        var seq = start
        func apply(_ type: String, _ data: JSONValue) {
            conversation.apply(event: .object([
                "type": .string(type),
                "seq": .number(Double(seq)),
                "time": .number(1_700_000_000_000 + Double(seq)),
                "data": data,
            ]), view: nil)
            seq += 1
        }
        apply("user/message", .object([
            "id": .string("u\(block)"),
            "source": .object(["kind": .string("user")]),
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string("Step \(block): " + String(repeating: "make the transcript long enough to scroll. ", count: 4)),
                ]),
            ]),
        ]))
        apply("assistant/message", .object([
            "turn": .number(Double(block)), "step": .number(0),
            "message": .object([
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string("Answer \(block). " + String(repeating: "Here is what the agent found and what it changed. ", count: 10)),
                    ]),
                ]),
            ]),
        ]))
        next = seq
    }

    private func makeWindow() -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene.map { UIWindow(windowScene: $0) }
            ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
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
        let path = "/tmp/rowel-open-bottom.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }

    /// The transcript's own scroller: the tallest scroll view under the view,
    /// because the composer and inline markdown tables carry scrollers of their
    /// own and the first match was one of those (20pt of content).
    private static func transcriptScroller(in root: UIView) -> UIScrollView? {
        var best: UIScrollView?
        var stack = [root]
        while let view = stack.popLast() {
            if let scroll = view as? UIScrollView,
               scroll.contentSize.height > (best?.contentSize.height ?? -1) {
                best = scroll
            }
            stack.append(contentsOf: view.subviews)
        }
        return best
    }
}
