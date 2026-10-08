/// Reading a conversation while an answer streams into it does not freeze the app.
///
/// The field report: "I was scrolling up and down while it answered, then it
/// would not scroll, and the whole screen froze" — and the screen stayed on,
/// because the main thread never came back. Instruments on the phone showed it
/// pinned inside SwiftUI for 100+ seconds: the transcript's `LazyVStack`
/// prefetching rows, re-measuring them, and asking for another prefetch from
/// inside every update. No Rowel code was running but `ConversationItem.id`.
///
/// Only a real device with real touches found it. Unit tests that replayed the
/// same conversation, presented sheets, moved the keyboard and set scroll
/// offsets never froze, on the simulator or on the phone; this script, which
/// drags with a finger while the keyboard follows it, froze the lazy stack
/// within ten gestures on two runs out of two. With the stack `ConversationView`
/// has now it ran 49 gestures across 12 streamed answers without one.
///
/// Off by default: it needs a paired machine, and it sends messages. It starts
/// a new conversation in the last folder used and asks for six markdown
/// answers — headings, a table, a list, no tools — which costs six model turns.
///
///   ROWEL_PAIR_LINK=$(node bridle/lib/cli.js pair --link | sed -n 's/^link: *//p') \
///     xcodebuild test -project Rowel.xcodeproj -scheme RowelUI \
///       -only-testing:RowelUITests/StreamingStaysResponsive
///
/// On a device that is already paired the link can be left out.

import XCTest

final class StreamingStaysResponsive: XCTestCase {
    /// How long one gesture may take before the app counts as gone. A gesture
    /// is a second or two of synthesized touches plus XCTest waiting for the
    /// app to go idle; a frozen app never does, and XCTest gives up on it after
    /// a minute.
    private let gestureBudget: TimeInterval = 40

    func testDraggingWhileAnswersStream() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-rowel.lock.enabled.v1", "NO"]
        let environment = ProcessInfo.processInfo.environment
        if let link = environment["ROWEL_PAIR_LINK"] ?? environment["TEST_RUNNER_ROWEL_PAIR_LINK"], !link.isEmpty {
            app.launchEnvironment["ROWEL_UITEST_PAIR_LINK"] = link
        }
        app.launch()

        // Wait for the list, so the button knows the last folder and starts a
        // conversation there instead of opening the folder browser.
        XCTAssertTrue(app.collectionViews.buttons.matching(identifier: "session.row").firstMatch
            .waitForExistence(timeout: 60), "the machine never sent a conversation list")
        let start = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'New conversation in'")).firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 30))
        start.tap()

        let field = app.textViews["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        let stats = app.buttons["conversation.stats"]
        let stop = app.buttons["Stop"]
        let done = app.buttons["Done"]
        let window = app.windows.firstMatch
        let middle = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        let low = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let high = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))

        let topics = [
            "how a laser particle sensor measures PM2.5",
            "why a kitchen hood cannot tell smoke from smog",
            "comparing indoor and outdoor air quality readings",
            "where particle sensors get their errors",
            "designing ventilation for a small kitchen",
            "common mistakes in home automation rules",
        ]
        for (round, topic) in topics.enumerated() {
            if done.exists { done.tap() }
            for _ in 0..<5 where app.keyboards.count == 0 { field.tap(); sleep(1) }
            field.typeText("Write about 600 words on \(topic). Use markdown: three headings, a four-row table and a list. Do not call any tools.")
            app.buttons["Send"].tap()
            XCTAssertTrue(stop.waitForExistence(timeout: 30), "answer \(round) never started")

            // The gestures that froze it: reading back with the keyboard up, so
            // it follows the finger down; the stats sheet opening and closing,
            // which hands the keyboard back; and dragging again at once.
            var gesture = 0
            while stop.exists, gesture < 40 {
                let began = Date()
                switch gesture % 4 {
                case 0:
                    middle.press(forDuration: 0.05, thenDragTo: low, withVelocity: .slow, thenHoldForDuration: 0.1)
                    low.press(forDuration: 0.05, thenDragTo: high, withVelocity: .default, thenHoldForDuration: 0)
                case 1:
                    if stats.exists, stats.isHittable {
                        stats.tap()
                        if done.waitForExistence(timeout: 5) { sleep(1); done.tap() }
                    }
                case 2:
                    field.tap()
                    middle.press(forDuration: 0.02, thenDragTo: low, withVelocity: .fast, thenHoldForDuration: 0)
                    low.press(forDuration: 0.02, thenDragTo: high, withVelocity: .fast, thenHoldForDuration: 0)
                default:
                    high.press(forDuration: 0.02, thenDragTo: low, withVelocity: .fast, thenHoldForDuration: 0)
                    if stats.exists, stats.isHittable {
                        stats.tap()
                        if done.waitForExistence(timeout: 5) { done.tap() }
                        middle.press(forDuration: 0.02, thenDragTo: low, withVelocity: .fast, thenHoldForDuration: 0)
                    }
                }
                let took = Date().timeIntervalSince(began)
                XCTAssertLessThan(took, gestureBudget,
                                  "answer \(round), gesture \(gesture) took \(Int(took)) s — the app stopped answering")
                gesture += 1
            }
            // The next question waits for this answer to finish.
            let deadline = Date().addingTimeInterval(120)
            while stop.exists, Date() < deadline { sleep(1) }
        }
    }
}
