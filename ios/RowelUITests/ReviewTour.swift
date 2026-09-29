/// The App Review walkthrough: the app from first launch through its typical use.
///
/// Review asked for a recording "from launch through the typical flow", and
/// the typical flow of a companion app starts before it can do anything: the
/// first-run screen, the setup it asks for on the Mac, pairing. Then what it
/// is for — the Mac's conversations arriving, one being read, and a permission
/// request answered from the phone.
///
/// Driven, like `Demo`, so the take can be re-made when the interface moves:
///
///   ios/demo.sh --review
///
/// Pairing follows the `rowel://pair` link Bridle prints — the simulator has no
/// camera to scan the QR with, and a tapped link is the same path. The script
/// opens it (`simctl openurl`) when this test drops a marker file: opening it
/// from here, with `XCUIApplication.open`, goes through the home screen and put
/// five seconds of it in the recording.
import XCTest

final class ReviewTour: XCTestCase {
    /// A beat long enough to read what is on screen.
    private let read: UInt32 = 4

    private var out: String {
        guard let path = ProcessInfo.processInfo.environment["ROWEL_SHOTS_OUT"], !path.isEmpty else {
            XCTFail("ROWEL_SHOTS_OUT is not set — run this through ios/demo.sh --review")
            return NSTemporaryDirectory()
        }
        return path
    }

    private var beats: [String: Double] = [:]

    private func beat(_ name: String) {
        beats[name] = Date().timeIntervalSince1970
    }

    override func tearDown() {
        let json = try? JSONSerialization.data(withJSONObject: beats, options: [.prettyPrinted, .sortedKeys])
        try? json?.write(to: URL(fileURLWithPath: out).appendingPathComponent("review-beats.json"))
        super.tearDown()
    }

    func testFirstLaunchThroughAnApproval() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-rowel.lock.enabled.v1", "NO",
        ]
        // A device that has never paired: the first screen anyone sees.
        app.launchEnvironment["ROWEL_UITEST_FRESH"] = "1"
        app.launch()

        XCTAssertTrue(app.buttons["Connect a Mac"].waitForExistence(timeout: 30))
        beat("welcome")
        sleep(read)

        // What the app asks the person to do on their Mac.
        app.buttons["Connect a Mac"].tap()
        XCTAssertTrue(app.staticTexts["On your Mac"].waitForExistence(timeout: 10))
        beat("setup")
        sleep(read + 2)

        // The pairing link Bridle printed: ask the script to open it.
        FileManager.default.createFile(atPath: (out as NSString).appendingPathComponent("pair-now"), contents: Data())

        // iOS sometimes asks before a link opens an app — not on a freshly
        // booted device, but on one that has asked before. Answer it if asked.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let open = springboard.alerts.buttons["Open"]
        if open.waitForExistence(timeout: 8) {
            sleep(1)
            open.tap()
        }

        // Pairing asks for notifications — it is how a stopped agent reaches
        // the phone later — and answering that is part of a first launch.
        let permit = springboard.alerts.buttons["Allow"]
        if permit.waitForExistence(timeout: 60) {
            beat("permission")
            sleep(2)
            permit.tap()
        }
        let list = app.descendants(matching: .any)["sessions.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 60), "pairing did not reach the conversation list")
        beat("paired")
        let dashboard = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Build the checkout health dashboard'")).firstMatch
        XCTAssertTrue(dashboard.waitForExistence(timeout: 60), "the Mac's conversations did not arrive")
        beat("listed")
        sleep(read)

        // A conversation: the agent's reply, its plan, its tool calls.
        dashboard.tap()
        beat("reading")
        sleep(read)
        app.swipeUp()
        sleep(2)
        app.swipeUp()
        sleep(2)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        sleep(2)

        // The agent stopped to ask. The whole command, answered from here.
        let waiting = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Ship the currency fix'")).firstMatch
        XCTAssertTrue(waiting.waitForExistence(timeout: 30), "no conversation waiting on approval — demo.sh arms one")
        waiting.tap()
        let allow = app.buttons["Allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 60), "nothing is waiting for approval in this conversation")
        beat("asked")
        sleep(read + 1)
        allow.tap()
        beat("allowed")
        sleep(12)
        beat("ended")
    }
}
