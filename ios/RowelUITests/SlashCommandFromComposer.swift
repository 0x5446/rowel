/// A slash command typed into the composer, from the keyboard to the machine.
///
/// `CommandSendTests` pins which call the store makes; `AccessMode` pins that the
/// Access rows agree with the machine. What neither can answer is whether the
/// thing a person actually does — type `/permission read-only` into the message
/// field and send — ends up at `commands/execute` rather than in the model's
/// lap. That is the whole point of the routing: a command sent as a prompt is
/// handed to the agent as words, silently, and looks like nothing happened.
///
/// So this runs against a real machine and checks both ends of it: the
/// transcript gets the machine's own `command/done` line, and the session's
/// access mode is what the command asked for. It puts the mode back before it
/// finishes.
///
/// Off by default: it needs a machine to talk to. Run it against a throwaway
/// harness (see the note in `.build-tmp/sessions.md`), not a real one:
///
///   ROWEL_HOME=~/rowel-shots/rowel-home node bridle/lib/cli.js pair --link
///   TEST_RUNNER_ROWEL_PAIR_LINK=<that link> xcodebuild test \
///     -project ios/Rowel.xcodeproj -scheme RowelUI \
///     -destination "platform=iOS Simulator,name=iPhone 17e" \
///     -only-testing:RowelUITests/SlashCommandFromComposer
///
/// A pairing token is single-use and briefly valid, so the link is wanted fresh.

import XCTest

final class SlashCommandFromComposer: XCTestCase {
    private var app: XCUIApplication!
    /// Generous: the far end is a real machine, and a command is a round trip
    /// through the Bridle before the projection comes back.
    private let remote: TimeInterval = 60

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

    func testAPermissionCommandTypedIntoTheComposerChangesTheSession() throws {
        guard pairLink?.isEmpty == false else {
            throw XCTSkip("no pairing link: this test needs a machine to talk to")
        }

        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 8) { allow.tap() }

        try openAConversation()

        // What this conversation runs under now, so the test can put it back.
        try openSessionInfo()
        let original = currentPreset()
        XCTAssertNotNil(original, "the sheet drew no selected preset: \(app.debugDescription)")
        closeSessionInfo()
        let before = original ?? "workspace-write"
        let target = before == "read-only" ? "workspace-write" : "read-only"

        // The act under test: type a command and send it.
        try send("/permission \(target)")

        // 1. The machine's own outcome line, in the transcript. This is the
        //    event stream's `command/done`, paired with the `command/run` that
        //    preceded it — a command run through the model would leave no such
        //    line at all.
        let outcome = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", "preset \(target)"))
            .firstMatch
        XCTAssertTrue(outcome.waitForExistence(timeout: remote),
                      "no command/done line for /permission \(target): \(app.debugDescription)")
        save("command-outcome")

        // 2. And the conversation is actually running under it.
        try openSessionInfo()
        XCTAssertTrue(waitForSelection(target),
                      "/permission \(target) was typed and answered, but the mode did not move")
        save("access-after-command")

        // Put it back, through the same door, and check the machine agreed.
        closeSessionInfo()
        try send("/permission \(before)")
        try openSessionInfo()
        XCTAssertTrue(waitForSelection(before), "the original preset did not come back")
    }

    // MARK: - The composer

    private func send(_ line: String) throws {
        let field = app.textViews["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: remote),
                      "the composer never appeared: \(app.debugDescription)")
        field.tap()
        field.typeText(line)

        let send = app.buttons["Send"]
        XCTAssertTrue(send.waitForExistence(timeout: 10), "no send button while a draft was waiting")
        XCTAssertTrue(send.isEnabled, "send stayed disabled with text in the field")
        send.tap()
        // The field empties on send, which is also how this knows the tap landed.
        let cleared = NSPredicate(format: "value == nil OR value == ''")
        expectation(for: cleared, evaluatedWith: field)
        waitForExpectations(timeout: 10)
    }

    // MARK: - Getting to the control

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

    private func closeSessionInfo() {
        // `waitForExistence`, because the sheet closing is not instant and the
        // next thing this test does is look for the composer behind it.
        let done = app.buttons["Done"].firstMatch
        if done.exists { done.tap() }
        let field = app.textViews["composer.field"]
        _ = field.waitForExistence(timeout: 10)
    }

    // MARK: - Reading the rows

    private func row(_ preset: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "access.\(preset)").firstMatch
    }

    private func currentPreset() -> String? {
        let deadline = Date().addingTimeInterval(remote)
        while Date() < deadline {
            if let found = presets.first(where: { row($0).isSelected }) { return found }
            usleep(300_000)
        }
        return nil
    }

    private func waitForSelection(_ preset: String) -> Bool {
        let deadline = Date().addingTimeInterval(remote)
        while Date() < deadline {
            if row(preset).isSelected { return true }
            usleep(500_000)
        }
        return false
    }

    private var pairLink: String? {
        let environment = ProcessInfo.processInfo.environment
        return environment["ROWEL_PAIR_LINK"] ?? environment["TEST_RUNNER_ROWEL_PAIR_LINK"]
    }

    private func save(_ name: String) {
        let directory = "/tmp/rowel-slash-command"
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: "\(directory)/\(name).png"))
        try? app.debugDescription.write(
            toFile: "\(directory)/\(name).tree.txt", atomically: true, encoding: .utf8)
    }
}
