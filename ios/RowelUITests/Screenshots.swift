/// Store screenshots, taken from the running app.
///
/// Not a test of anything: a driver that walks the app the way the App Store
/// listing shows it and writes PNGs where the release tooling can pick them up.
/// It runs against a real Bridle and a real harness, so what lands in the files
/// is the product rather than a mock of it.
///
/// Kept out of the ordinary suite by name — run it deliberately:
///
///   xcodebuild test -scheme RowelUI -only-testing:RowelUITests/Screenshots
///
/// Each shot proves it is looking at the right screen before it saves. A
/// screenshot taken on faith is worse than a missing one: it reaches the store
/// listing showing the wrong page, and nothing fails to say so.
///
/// The destination is a host path. The simulator sees the host file system, so
/// the shots appear directly in the repo rather than inside a container.

import XCTest

final class Screenshots: XCTestCase {
    private var app: XCUIApplication!
    /// Where the shots are written, on the host.
    ///
    /// From the environment, not a constant. The simulator sees the host file
    /// system, so this has to be an absolute path — and an absolute path
    /// written into the source is one machine's path: it carries whoever owns
    /// that machine into a public repository, and on anybody else's it silently
    /// writes somewhere that does not exist. Missing is a failure, not a
    /// default; a default would put the shots where nobody looks.
    private var out: String {
        guard let path = ProcessInfo.processInfo.environment["ROWEL_SHOTS_OUT"],
              !path.isEmpty else {
            XCTFail("ROWEL_SHOTS_OUT is not set — run this through the script that sets it")
            return NSTemporaryDirectory()
        }
        return path
    }
    private let patience: TimeInterval = 60
    /// Counts failed attempts so their screenshots do not overwrite each other.
    private var attempts = 0

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-rowel.lock.enabled.v1", "NO",
        ]
        // Pair from the environment when a link is supplied, the same way
        // FlowTests does. A deep link opened with `simctl openurl` stops on a
        // system "Open in Rowel?" alert that nothing in this process can reach.
        if let link = ProcessInfo.processInfo.environment["ROWEL_PAIR_LINK"], !link.isEmpty {
            app.launchEnvironment["ROWEL_UITEST_PAIR_LINK"] = link
        }
        try connect()
    }

    /// Launch, and wait until the machine has actually answered.
    ///
    /// The compose button is on screen whether or not the tunnel is up, so
    /// waiting for it proves nothing — a run gated on it walks an empty list
    /// and saves screenshots of a blank app. A conversation row only exists
    /// once the machine has sent one.
    private func connect(file: StaticString = #filePath, line: UInt = #line) throws {
        for attempt in 0..<2 {
            if attempt > 0 { app.terminate(); sleep(3) }
            app.launch()
            let anyRow = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] '/Users/'")).firstMatch
            if anyRow.waitForExistence(timeout: patience) { return }
        }
        XCTFail("the app never reached the machine", file: file, line: line)
    }

    /// Back to a known screen, without guessing how deep we are.
    private func restart() throws {
        app.terminate()
        sleep(2)
        try connect()
    }

    private func save(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let url = URL(fileURLWithPath: out).appendingPathComponent("\(name).png")
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: out), withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: url)
    }

    /// Open a conversation with this title that actually has something in it.
    ///
    /// Two faults used to meet here, and they produced the same picture: a
    /// store screenshot of an empty app, saved without complaint.
    ///
    /// The seed leaves more than one conversation per title and the spares are
    /// empty. Being newest, they sort to the top of the list, so `firstMatch`
    /// landed on exactly the wrong row every time. And the check that followed
    /// — that a static text carrying the title exists — is satisfied the
    /// instant the screen appears, because the navigation bar shows that same
    /// title. It could not fail, so it never did.
    ///
    /// Both are fixed by asking the only question that matters: is there a
    /// transcript on screen. Rows are tried in order until one answers yes.
    ///
    /// The card is the button and its label carries the title, the folder and
    /// the age, so match a prefix rather than the whole string.
    private func openSession(
        _ title: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let rows = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title))
        // The list is lazy, so a row below the fold does not exist as far as
        // this process is concerned. Waiting longer never conjures it — only
        // scrolling does, which is why a run could report "no row for" a
        // conversation that was plainly in the list.
        var scrolls = 0
        while !rows.firstMatch.waitForExistence(timeout: scrolls == 0 ? 20 : 2) {
            XCTAssertLessThan(scrolls, 8, "no row for \(title)", file: file, line: line)
            app.swipeUp()
            scrolls += 1
        }
        // Rows carrying the same title are not interchangeable — some of them
        // are conversations that never ran — and the list is lazy, so they are
        // not all reachable at once either. Try what is on screen, scroll, try
        // again; a title that appears three times may have its only real copy
        // below the fold.
        for pass in 0..<4 {
            if pass > 0 {
                app.swipeUp()
                sleep(1)
            }
            for index in 0..<rows.count {
                rows.element(boundBy: index).tap()
                if transcriptLoaded() { return }
                // Wrong one: back out and try the next row with this title.
                app.navigationBars.buttons.element(boundBy: 0).tap()
                XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 20),
                              "did not get back to the list", file: file, line: line)
            }
        }
        // Keep the evidence. "Was empty" is what this code can conclude, not
        // necessarily what happened — a history call that failed leaves the
        // same blank transcript as one that succeeded with nothing in it — and
        // without the screen it produced, the next person debugging this is
        // back to guessing from a timing difference.
        saveDiagnostic("failed-\(title.prefix(20).replacingOccurrences(of: " ", with: "-"))")
        XCTFail("no conversation called \(title) showed a transcript", file: file, line: line)
    }

    /// Wait until the conversation on screen is showing its transcript.
    ///
    /// The view has exactly three states that are not a transcript, and it
    /// names all three, so this asks about those rather than trying to
    /// recognise content: "Opening…" before the conversation object exists,
    /// "Loading this conversation…" while history is in flight, and "Nothing
    /// here yet" once history has arrived and held nothing.
    ///
    /// The third is decisive — an empty conversation will not fill in later —
    /// so it returns immediately instead of waiting out the timeout. Polling
    /// rather than sleeping a fixed number: history crosses a tunnel, and how
    /// long that takes is not something a constant can be right about.
    /// - Parameter timeout: how long to allow before calling it empty.
    /// - Returns: true once a transcript is on screen.
    private func transcriptLoaded(timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.staticTexts["Nothing here yet"].exists {
                note("empty")
                return false
            }
            if !app.staticTexts["Opening…"].exists
                && !app.staticTexts["Loading this conversation…"].exists {
                return true
            }
            usleep(400_000)
        }
        note("stuck")
        return false
    }

    /// Photograph a screen that did not do what was expected, before leaving it.
    ///
    /// The failure screenshot used to be taken at the end, by which point the
    /// driver had already backed out to the list — so what it recorded was the
    /// list, and the screen that actually went wrong was gone.
    private func note(_ why: String) {
        attempts += 1
        saveDiagnostic("failure-\(why)-\(attempts)")
    }

    /// A picture of something that went wrong, kept away from the shots.
    ///
    /// These are photographs of screens that failed their own check: an
    /// unexpected page, somebody else's session, an error. Writing them beside
    /// the store assets puts exactly the wrong images one `git add -A` away
    /// from a public repository, and leaves the publishing step a directory it
    /// cannot tell good files from bad in.
    private func saveDiagnostic(_ name: String) {
        let directory = URL(fileURLWithPath: out)
            .deletingLastPathComponent().appendingPathComponent("diagnostics")
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: directory.appendingPathComponent("\(name).png"))
        try? app.debugDescription.write(
            to: directory.appendingPathComponent("\(name).tree.txt"),
            atomically: true, encoding: .utf8)
    }

    /// The machine's name, and the identity the pairing is anchored to.
    func test1Machine() throws {
        app.buttons["gearshape"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        // The paired machine sits under this phone's own settings.
        var row = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'MacBook' AND label CONTAINS[c] ':'")).firstMatch
        for _ in 0..<5 where !row.exists {
            app.swipeUp()
            sleep(1)
            row = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] 'MacBook' AND label CONTAINS[c] ':'")).firstMatch
        }
        if !row.exists {
            row = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] 'MacBook'")).element(boundBy: 0)
        }
        try? app.debugDescription.write(
            toFile: "\(out)/tree-settings.txt", atomically: true, encoding: .utf8)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no paired machine row")
        row.tap()
        sleep(2)

        let name = app.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 10), "no name field — wrong page")
        name.tap()
        sleep(1)
        if let existing = name.value as? String, !existing.isEmpty {
            name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,
                                 count: existing.count))
        }
        app.typeText("MacBook Pro")
        if app.keyboards.buttons["return"].exists { app.keyboards.buttons["return"].tap() }
        sleep(2)
        XCTAssertTrue(app.staticTexts["Fingerprint"].exists, "not the machine page")
        save("machine")
    }

    /// The list, grouped by folder, with anything waiting on a person on top.
    func test2Sessions() throws {
        // connect() already proved the list is populated.
        sleep(3)
        save("sessions")
    }

    /// A finished answer, and the model picker over it.
    func test3Conversation() throws {
        try openSession("Add CAD and AUD to the currency table")
        // `openSession` returns with a transcript already on screen, so this is
        // only the scroll settling, not a guess at how long history takes.
        sleep(2)
        save("conversation")

        app.navigationBars.buttons.element(boundBy: 1).tap()
        XCTAssertTrue(app.staticTexts["Model"].waitForExistence(timeout: 10))
        sleep(2)
        save("models")
    }

    /// The card that stops a command until a person answers it.
    func test4Approval() throws {
        try openSession("Ship the currency fix")
        sleep(2)
        save("approval")
    }

    /// A long job: the artifact at the end, the tools it ran, the plan it wrote
    /// for itself. Scrolling back is scrolling through the work.
    func test5Working() throws {
        try openSession("Build the checkout health dashboard")
        sleep(2)
        save("artifact")
        app.swipeDown()
        app.swipeDown()
        sleep(2)
        save("tools")
        app.swipeDown()
        app.swipeDown()
        sleep(2)
        save("plan")
    }

    /// A photograph already in the conversation: a layout sketched on paper,
    /// sent from the phone, and the model working from it.
    ///
    /// Driven from the machine side rather than through the system photo
    /// picker — the picker runs out of process and does not take synthetic
    /// taps, and what matters in the shot is the sketch in the transcript, not
    /// the moment of choosing it.
    func test6Photo() throws {
        try openSession("Match the dashboard to this sketch")
        sleep(2)
        // Back up to the message itself — the sketch is the point of the shot.
        app.swipeDown()
        app.swipeDown()
        app.swipeDown()
        // Whole swipes land the sketch thumbnail half under the navigation
        // bar, deterministically — three of them always stop at the same
        // frame. One measured drag brings the attachment fully on screen,
        // which is the one thing this shot exists to show.
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.52))
        from.press(forDuration: 0.05, thenDragTo: to)
        // Wait for the sketch itself, not for a duration. A thumbnail that has
        // not arrived draws a grey placeholder, and a placeholder photographs
        // exactly as well as the photo does — which is how a shot of the
        // failure reached the App Store and stayed there. The image element
        // only carries a label once real bytes are behind it.
        let sketch = app.images["attachment.loaded"]
        XCTAssertTrue(sketch.waitForExistence(timeout: 30),
                      "the attachment never loaded — this shot would be of the placeholder")
        sleep(1)
        save("photo")
    }
}
