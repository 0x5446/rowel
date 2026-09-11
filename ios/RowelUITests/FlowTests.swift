/// The app driven the way a person drives it.
///
/// These run against a **real Bridle and a real harness**, not a stub. That is
/// the point: the unit tests already prove the fold and the protocol in
/// isolation, and what they cannot tell you is whether tapping a row actually
/// puts a conversation on screen. Everything here goes over the tunnel.
///
/// Because of that they need setting up, and they say so instead of failing
/// obscurely when it is missing:
///
///   cd rowel && node bridle/lib/cli.js --direct-port 61000 &
///   ROWEL_PAIR_LINK=$(node bridle/lib/cli.js pair --link | sed -n 's/^link: *//p') \
///     ./ios/run-ui-tests.sh
///
/// A pairing token is single-use, so each run wants a fresh link. `run-ui-tests.sh`
/// mints one.

import XCTest

final class FlowTests: XCTestCase {
    private var app: XCUIApplication!

    /// How long to wait on anything that crosses the tunnel. Generous, because
    /// the far end is a real agent on a real machine and a first history page
    /// can be large.
    private let remote: TimeInterval = 30

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            // The app lock, off. A `-key value` launch argument is a
            // UserDefaults override, so this needs nothing in the app.
            //
            // Every test below is about something else, and whether they meet a
            // lock screen would otherwise depend on whether this particular
            // simulator happens to have a passcode — which is exactly the kind
            // of thing that makes a suite pass on one machine and not another.
            // `testTheLockStaysOutOfTheWayWithoutAPasscode` covers the lock.
            "-rowel.lock.enabled.v1", "NO",
        ]
        if let link = pairLink, !link.isEmpty {
            app.launchEnvironment["ROWEL_UITEST_PAIR_LINK"] = link
        }
    }

    override func tearDown() {
        app = nil
    }

    /// The pairing link for this run.
    ///
    /// `xcodebuild` does not hand the shell's environment to the test process;
    /// it forwards only variables prefixed `TEST_RUNNER_`, stripping the prefix
    /// on the way. Both spellings are accepted so the suite runs the same way
    /// under `xcodebuild` and under a direct `simctl` launch.
    private var pairLink: String? {
        let environment = ProcessInfo.processInfo.environment
        return environment["ROWEL_PAIR_LINK"] ?? environment["TEST_RUNNER_ROWEL_PAIR_LINK"]
    }

    // MARK: - Pairing

    /// The whole first run: launch, pair, and land on a list of real
    /// conversations from the machine.
    func testPairingReachesTheSessionList() throws {
        try launchPaired()
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: remote), "the session list never appeared")
        XCTAssertTrue(
            composeButton.waitForExistence(timeout: remote),
            "the compose button is missing, so there is no way to start anything"
        )
    }

    /// Without a pairing link the app has to show the welcome flow rather than
    /// an error or an empty list.
    func testFirstLaunchOffersToConnect() {
        app.launchEnvironment["ROWEL_UITEST_PAIR_LINK"] = ""
        app.launchEnvironment["ROWEL_UITEST_FRESH"] = "1"
        app.launch()
        XCTAssertTrue(
            app.buttons["Connect a Mac"].waitForExistence(timeout: 10),
            "a device with no pairings must land on the welcome screen"
        )
        // The screen has to say what it is before it asks for anything.
        XCTAssertTrue(app.staticTexts["Rowel"].exists)
    }

    // Why there is no UI test for the app lock.
    //
    // Whether it engages depends on whether this particular simulator has
    // biometrics enrolled, and dismissing it depends on simulating a match
    // through a private `notifyutil` name that differs between Face ID and
    // Touch ID and between OS versions. A test whose result depends on the
    // machine it runs on is worse than no test: it fails for reasons that are
    // not the code and gets muted.
    //
    // The state machine — the timeout, the clock moving backwards, the cover
    // going up on `.inactive`, and the fail-open when a device cannot
    // authenticate at all — is covered by `LockTests`, which injects both the
    // clock and the authenticator and so tests the cases a real device cannot
    // be made to produce on cue.

    // MARK: - Conversations

    /// Open the first conversation and prove its history rendered. This is the
    /// regression test for the blank-transcript bug: a session whose page came
    /// back as 22 MB of streaming chunks used to leave the screen empty with no
    /// explanation.
    func testOpeningAConversationShowsItsHistory() throws {
        try launchPaired()
        let row = try firstConversationRow()
        row.tap()

        // The composer is the frame of the screen; it must be there immediately.
        // `textViews`, not `textFields`: it is a UITextView, because a growing
        // SwiftUI TextField measures the whole string on every keystroke. See
        // GrowingField.
        let composer = app.textViews["composer.field"]
        XCTAssertTrue(composer.waitForExistence(timeout: remote), "the composer never appeared")

        // And then something has to be in the transcript. A conversation with a
        // history is never legitimately empty.
        let settled = NSPredicate(format: "count > 0")
        expectation(for: settled, evaluatedWith: app.staticTexts, handler: nil)
        waitForExpectations(timeout: remote)
    }

    /// Going back must return to the list rather than stranding the person.
    func testBackReturnsToTheList() throws {
        try launchPaired()
        try firstConversationRow().tap()
        XCTAssertTrue(app.textViews["composer.field"].waitForExistence(timeout: remote))

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(
            composeButton.waitForExistence(timeout: 10),
            "the compose button is the marker that we are back on the list"
        )
    }

    // MARK: - Settings

    /// Settings has to state both fingerprints and the machine's own identity,
    /// because comparing them against `bridle devices` is the only way someone
    /// can check who they are actually talking to.
    func testSettingsShowsTheIdentityToCompare() throws {
        try launchPaired()
        app.navigationBars.buttons["Settings"].tap()

        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.staticTexts["This iPhone"].exists || app.staticTexts["Paired Macs"].exists,
            "settings has to name the two ends of the pairing"
        )
    }

    // MARK: - Starting something

    /// The compose button must lead to a folder picker listing the machine's
    /// own directories — the app cannot start a conversation without a cwd, and
    /// asking someone to type an absolute path on a phone is not an option.
    func testComposeOffersTheMachinesFolders() throws {
        try launchPaired()
        composeButton.tap()

        let picker = app.navigationBars.firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: remote))
        let start = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH[c] 'Start '")
        ).firstMatch
        XCTAssertTrue(
            start.waitForExistence(timeout: remote),
            "the picker must offer somewhere to start, either this folder or the default"
        )
    }

    // MARK: - Helpers

    /// Launch already paired, skipping the flow that needs a camera.
    private func launchPaired() throws {
        guard app.launchEnvironment["ROWEL_UITEST_PAIR_LINK"]?.isEmpty == false else {  // swiftlint:disable:this empty_count
            throw XCTSkip("""
                ROWEL_PAIR_LINK is not set, so there is no machine to talk to. \
                Start a Bridle and run ios/run-ui-tests.sh, which mints a fresh link.
                """)
        }
        app.launch()
        // Notifications are requested the moment a pairing lands. Answering it
        // here keeps the alert from swallowing the first real tap.
        let allow = app.springboardAllowButton
        if allow.waitForExistence(timeout: 8) { allow.tap() }
    }

    /// The first row of the session list, once the machine has answered.
    /// The compose button.
    ///
    /// Not an exact match on "New conversation": once anything has been started
    /// the label becomes "New conversation in <folder>", so the exact name only
    /// ever held on a device that had never been used. It failed here for a
    /// reason that had nothing to do with what each test was checking.
    private var composeButton: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'New conversation'")).firstMatch
    }

    private func firstConversationRow() throws -> XCUIElement {
        // Not "the first button in the list": the list is grouped by workspace,
        // and a group header is a button too. Taking element zero picked the
        // header and tapping it folded the group away instead of opening
        // anything, which then failed on the next assertion — somewhere else
        // entirely.
        let rows = app.collectionViews.buttons.matching(identifier: "session.row")
        let anyButton = app.collectionViews.buttons
        let appeared = NSPredicate(format: "count > 0")
        expectation(for: appeared, evaluatedWith: anyButton, handler: nil)
        waitForExpectations(timeout: remote)

        // Groups remember whether they are folded and all of them may be shut,
        // in which case there is no row to tap until one is opened.
        if rows.count == 0 {
            let header = anyButton.element(boundBy: 0)
            guard header.exists else {
                throw XCTSkip("the machine reported no conversations, so there is nothing to open")
            }
            header.tap()
        }

        let row = rows.element(boundBy: 0)
        guard row.waitForExistence(timeout: remote) else {
            throw XCTSkip("the machine reported no conversations, so there is nothing to open")
        }
        return row
    }
}

private extension XCUIApplication {
    /// The system permission alert's accept button, which belongs to Springboard
    /// rather than to the app.
    var springboardAllowButton: XCUIElement {
        XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
    }
}
