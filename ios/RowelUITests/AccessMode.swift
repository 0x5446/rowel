/// The access mode of a running conversation, changed from the phone.
///
/// Session ▸ Access was read-only for a while, on the finding that a session's
/// mode is fixed when the conversation starts. That finding was wrong — it was
/// measured through the one write the app had (`settings.update`, which sets
/// the default for *new* conversations) — and the mode is in fact changed by
/// the machine's `/permission` command, which writes to that one session's log.
/// `SessionAccessTests` pins the call the app makes; what only this test can
/// answer is whether the thing a person touches does that: a real conversation
/// over a real tunnel, a real tap on a real row, and a real Mac that has to
/// agree before the checkmark moves.
///
/// Three things are checked, in the order someone would check them:
///
///  1. the row that is current says so (the app draws a checkmark from the
///     projection, and the projection is the machine's answer, not a guess);
///  2. tapping a different preset moves it — which it cannot do unless the
///     command reached the Mac and the Mac's `permissions` projection came
///     back changed;
///  3. full access asks first, and cancelling it changes nothing. It is the one
///     preset that drops the sandbox and the approval prompts together, so a
///     misplaced tap there is the expensive kind of mistake.
///
/// Off by default: it needs a machine to talk to, and it changes that machine's
/// session (it puts the mode back before it finishes). Run it against a
/// throwaway harness rather than a real one:
///
///   ROWEL_SHOTS_DEVICE="iPhone 17e" ios/screenshots.sh --seed
///   ROWEL_HOME=~/rowel-shots/rowel-home node bridle/lib/cli.js pair --link
///   TEST_RUNNER_ROWEL_PAIR_LINK=<that link> xcodebuild test \
///     -project ios/Rowel.xcodeproj -scheme RowelUI \
///     -destination "platform=iOS Simulator,name=iPhone 17e" \
///     -only-testing:RowelUITests/AccessMode
///
/// A pairing token is single-use, so the link is minted in the same breath as
/// the run.

import XCTest

final class AccessMode: XCTestCase {
    private var app: XCUIApplication!
    /// Generous: the far end is a real machine, and a switch is a round trip
    /// through the Bridle before the projection comes back.
    private let remote: TimeInterval = 60

    /// The presets, in the order the sheet draws them.
    private let presets = ["read-only", "workspace-write", "danger-full-access"]

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

    func testTheAccessModeCanBeChangedFromThePhone() throws {
        guard pairLink?.isEmpty == false else {
            throw XCTSkip("no pairing link: this test needs a machine to talk to")
        }

        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 8) { allow.tap() }

        try openAConversation()
        try openSessionInfo()

        // 1. The sheet says which preset this conversation is running under.
        let current = try currentPreset()
        XCTAssertTrue(current != nil, "the sheet drew no selected preset: \(app.debugDescription)")
        let original = current ?? "workspace-write"

        // 2. A tap on another one moves it — through the Mac, not locally.
        let target = original == "read-only" ? "workspace-write" : "read-only"
        tap(target)
        XCTAssertTrue(waitForSelection(target),
                      "\(target) never became the current preset — the switch did not reach the Mac")
        XCTAssertFalse(row(original).isSelected, "two presets were selected at once")

        // 3. Full access asks first, and backing out of the question is enough.
        tap("danger-full-access")
        let confirm = app.buttons["Turn on full access"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10),
                      "full access was offered without a confirmation")
        save("full-access-confirmation")
        // The way out is the platform's, not a button: the system presents this
        // as a popover and drops the `.cancel` role item, because tapping away
        // from a popover is how one is dismissed. (Measured — the tree for that
        // screen holds one button, the destructive one, and a person reading it
        // sees the dimmed backdrop behind.)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(confirm.exists, "the question stayed up after a tap outside it")
        XCTAssertFalse(row("danger-full-access").isSelected,
                       "dismissing the confirmation still turned full access on")

        // Put the conversation back the way it was found, and check that the
        // machine said so — a test that leaves a session changed is a test the
        // next run cannot trust.
        tap(original)
        XCTAssertTrue(waitForSelection(original), "the original preset did not come back")
        save("access")
    }

    // MARK: - Getting to the control

    /// The first conversation in the list.
    private func openAConversation() throws {
        let rows = app.collectionViews.buttons.matching(identifier: "session.row")
        let deadline = Date().addingTimeInterval(remote)
        while Date() < deadline && rows.count == 0 {
            usleep(500_000)
        }
        guard rows.count > 0 else {
            save("no-list")
            throw XCTSkip("the machine sent no conversation list")
        }
        rows.element(boundBy: 0).tap()
    }

    /// Session ▸ Access, through the conversation's own menu.
    ///
    /// Not through the stat strip under the composer, which is the nicer tap for
    /// a person: the strip only draws itself when there is a number to show, so
    /// a conversation that has not run a turn yet has no strip to tap. The menu
    /// is there either way, and it is the same sheet.
    private func openSessionInfo() throws {
        let menu = app.buttons["conversation.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: remote),
                      "the conversation never drew its toolbar: \(app.debugDescription)")
        menu.tap()

        let item = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Session"))
            .firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10),
                      "the conversation menu offered no Session row: \(app.debugDescription)")
        item.tap()

        XCTAssertTrue(row("read-only").waitForExistence(timeout: remote),
                      "the sheet drew no access rows: \(app.debugDescription)")
    }

    // MARK: - Reading and touching the rows

    /// The rows are buttons carrying a system identifier; the checkmark is a
    /// picture, so "which one is current" is the `.isSelected` trait.
    private func row(_ preset: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "access.\(preset)").firstMatch
    }

    private func currentPreset() throws -> String? {
        let deadline = Date().addingTimeInterval(remote)
        while Date() < deadline {
            if let found = presets.first(where: { row($0).isSelected }) { return found }
            usleep(300_000)
        }
        return nil
    }

    private func tap(_ preset: String) {
        let element = row(preset)
        XCTAssertTrue(element.waitForExistence(timeout: remote), "no row for \(preset)")
        element.tap()
    }

    private func waitForSelection(_ preset: String) -> Bool {
        let deadline = Date().addingTimeInterval(remote)
        while Date() < deadline {
            if row(preset).isSelected { return true }
            usleep(500_000)
        }
        return false
    }

    // MARK: - Evidence

    private var pairLink: String? {
        let environment = ProcessInfo.processInfo.environment
        return environment["ROWEL_PAIR_LINK"] ?? environment["TEST_RUNNER_ROWEL_PAIR_LINK"]
    }

    /// Keep the screen, and the hierarchy that produced it, for the cases where
    /// the failure is the only thing that says what went wrong.
    private func save(_ name: String) {
        let directory = "/tmp/rowel-access-mode"
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: "\(directory)/\(name).png"))
        try? app.debugDescription.write(
            toFile: "\(directory)/\(name).tree.txt", atomically: true, encoding: .utf8)
    }
}
