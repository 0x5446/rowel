/// Opening a conversation puts you at the end of it.
///
/// The field report, one line long: "every time I open a session I have to
/// scroll all the way down myself". The transcript asked for its end after the
/// layout that builds it — a `scrollTo` inside the same pass that is still
/// building the content it means to scroll to — so a conversation opened at the
/// top of its own history and stayed there until the reader dragged it down.
/// The open position is now the scroll view's own anchor; see `FollowState` and
/// `ConversationView`.
///
/// This is the half only the app can answer: a real conversation over a real
/// tunnel, with the composer under it. A conversation is long enough to matter
/// when the machine still has earlier pages to offer — `hasMore`, which the
/// view draws as its own "Load earlier messages" control — so the check runs on
/// the first conversation in the list that has any, and reads the fault as the
/// thing the reader sees rather than as a coordinate: the button that appears
/// when a transcript is not at its end.
///
/// Off by default: it needs a machine to talk to and it opens somebody's real
/// session.
///
///   ROWEL_PAIR_LINK=$(node bridle/lib/cli.js pair --link | sed -n 's/^link: *//p') \
///     xcodebuild test -project Rowel.xcodeproj -scheme RowelUI \
///       -only-testing:RowelUITests/OpeningPosition
///
/// A pairing token is single-use and briefly valid, so the link is wanted
/// fresh, minted in the same breath as the run.

import XCTest

final class OpeningPosition: XCTestCase {
    private var app: XCUIApplication!
    /// Generous: the far end is a real agent on a real machine, and a first
    /// history page can be large.
    private let remote: TimeInterval = 60

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-rowel.lock.enabled.v1", "NO",
        ]
        if let link = pairLink, !link.isEmpty {
            app.launchEnvironment["ROWEL_UITEST_PAIR_LINK"] = link
        }
    }

    override func tearDown() {
        app = nil
    }

    func testOpeningAConversationLandsAtTheEnd() throws {
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 8) { allow.tap() }

        try reachSessionList()

        // The first conversation with earlier pages behind it is the one this
        // report was about; a conversation whose whole history fits on screen
        // has no end to miss and would prove nothing either way.
        for row in sessionRows().prefix(20) {
            let title = row.label
            row.tap()
            guard app.textViews["composer.field"].waitForExistence(timeout: remote) else {
                XCTFail("\(title) never opened")
                return
            }
            // History landing, then settling: the tail paints first and the
            // rest of the page follows behind it.
            let earlier = app.buttons["Load earlier messages"]
            _ = earlier.waitForExistence(timeout: 20)
            Thread.sleep(forTimeInterval: 3)
            guard earlier.exists else {
                back()
                continue
            }

            let bottom = transcriptBottom()
            let ceiling = app.textViews["composer.field"].frame.minY
            save("opened")
            XCTAssertFalse(
                app.buttons["Back to bottom"].exists,
                "\(title) opened away from its own end — the reader is offered "
                + "'Back to bottom' on a conversation they just opened"
            )
            XCTAssertGreaterThan(
                bottom, ceiling - app.frame.height * 0.8,
                "\(title): the newest line is \(Int(ceiling - bottom))pt above the composer, "
                + "which is the 'I have to scroll down myself every time' report"
            )
            return
        }
        // Thrown, not constructed. As a bare expression this was a discarded
        // value: the test returned normally, Xcode reported success, and a run
        // that checked nothing looked exactly like a run that checked and
        // passed. That is the worst failure a test can have.
        throw XCTSkip("no conversation in the list had earlier pages to check")
    }

    // MARK: - Helpers

    private var pairLink: String? {
        let environment = ProcessInfo.processInfo.environment
        return environment["ROWEL_PAIR_LINK"] ?? environment["TEST_RUNNER_ROWEL_PAIR_LINK"]
    }

    /// The lowest point of drawn transcript text, on screen.
    private func transcriptBottom() -> CGFloat {
        let composer = app.textViews["composer.field"].frame
        return app.staticTexts.allElementsBoundByIndex
            .filter { $0.frame.height > 1 && $0.frame.width > 1 && $0.frame.maxY <= composer.minY }
            .map(\.frame.maxY)
            .max() ?? 0
    }

    private func reachSessionList() throws {
        let anyButton = app.collectionViews.buttons
        // Waiting rather than asserting, so a machine that never answered
        // leaves a picture of what was on screen instead of a bare timeout.
        let deadline = Date().addingTimeInterval(remote)
        while Date() < deadline && anyButton.count == 0 {
            usleep(500_000)
        }
        guard anyButton.count > 0 else {
            save("no-list")
            XCTFail("the machine never sent a conversation list")
            return
        }
    }

    /// Conversations, in the order the list shows them. Groups remember whether
    /// they are folded and the list is lazy, so a shut group is opened first and
    /// the list is scrolled to reach more — element zero is a header, not a
    /// conversation.
    private func sessionRows() -> [XCUIElement] {
        let rows = app.collectionViews.buttons.matching(identifier: "session.row")
        if rows.count == 0, app.collectionViews.buttons.count > 0 {
            app.collectionViews.buttons.element(boundBy: 0).tap()
            Thread.sleep(forTimeInterval: 1)
        }
        // The long conversations are the older ones, and the list is lazy: it
        // has to be walked to reach them.
        var seen = Set<String>()
        var found: [XCUIElement] = []
        for _ in 0..<8 {
            for index in 0..<rows.count {
                let row = rows.element(boundBy: index)
                // A row that is off screen has no activation point, and asking
                // is an error rather than a false — `exists` alone is the
                // question that can always be answered.
                guard row.exists else { continue }
                guard seen.insert(row.label).inserted else { continue }
                found.append(row)
            }
            if found.count >= 20 { break }
            app.swipeUp()
            Thread.sleep(forTimeInterval: 1)
        }
        return found
    }

    private func back() {
        app.navigationBars.buttons.element(boundBy: 0).tap()
        Thread.sleep(forTimeInterval: 1)
    }

    /// Keep the screen, and the hierarchy that produced it.
    private func save(_ name: String) {
        let directory = "/tmp/rowel-opening-position"
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: "\(directory)/\(name).png"))
        try? app.debugDescription.write(
            toFile: "\(directory)/\(name).tree.txt", atomically: true, encoding: .utf8)
    }
}
