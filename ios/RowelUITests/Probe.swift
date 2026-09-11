/// Time how long each conversation takes to open, against a real machine.
///
/// Built for one field report — "it just froze" seven seconds after launch,
/// over mobile data, with no crash log attached — that nothing in the unit
/// suite could reproduce: the pages were small, the parser was off the main
/// thread, and no blocking primitive was anywhere in the app. What was left
/// was to open real conversations on a real harness and watch. XCUITest
/// queries are answered by the app's main thread, so a hung main thread shows
/// up here as a query that takes the whole timeout, which is the measurement.
///
/// Off by default: it needs a machine to talk to, and it walks whatever that
/// machine has. Run with `ROWEL_PROBE_ROWS=8` for the first rows, or
/// `ROWEL_PROBE_MATCH="title one,title two"` for particular conversations
/// (found by scrolling, like the screenshot driver). Each line it prints
/// starts with `[PROBE]`, and pairs with a Time Profiler attached to the app.

import XCTest

final class Probe: XCTestCase {
    private var app: XCUIApplication!
    private let patience: TimeInterval = 240

    override func setUpWithError() throws {
        let rows = ProcessInfo.processInfo.environment["ROWEL_PROBE_ROWS"]
        let match = ProcessInfo.processInfo.environment["ROWEL_PROBE_MATCH"]
        try XCTSkipIf(rows == nil && match == nil, "set ROWEL_PROBE_ROWS or ROWEL_PROBE_MATCH")
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-rowel.lock.enabled.v1", "NO"]
        if let link = ProcessInfo.processInfo.environment["ROWEL_PAIR_LINK"], !link.isEmpty {
            app.launchEnvironment["ROWEL_UITEST_PAIR_LINK"] = link
        }
    }

    func testOpenConversations() throws {
        let started = Date()
        app.launch()
        let rows = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] '/Users/'"))
        // Slow is a measurement here, not a failure: the field report was
        // ninety seconds of "connecting" over mobile data.
        let reached = rows.firstMatch.waitForExistence(timeout: patience)
        report("launch→list", since: started, state: reached ? "ok" : "TIMEOUT")
        guard reached else { dumpScreen("launch→list timed out"); return }

        let env = ProcessInfo.processInfo.environment
        if let wanted = env["ROWEL_PROBE_MATCH"] {
            for title in wanted.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                openMatching(title, rows: rows)
            }
        } else {
            let count = min(Int(env["ROWEL_PROBE_ROWS"] ?? "6") ?? 6, rows.count)
            for index in 0..<count {
                // Re-query each time: the list re-sorts when a machine event
                // moves a row, and a stale element taps the wrong one.
                let row = rows.element(boundBy: index)
                open(row, label: row.label)
            }
        }
    }

    /// Find a conversation the way a person does: type into the search field.
    /// Scrolling a lazy list of a hundred and fifty rows for a title that may
    /// be rendered differently from how the harness stores it found nothing.
    private func openMatching(_ title: String, rows: XCUIElementQuery) {
        let search = app.searchFields.firstMatch
        guard search.waitForExistence(timeout: 10) else { return report(title, since: Date(), state: "no-search-field") }
        search.tap()
        search.typeText(String(title.prefix(20)))
        let row = rows.firstMatch
        guard row.waitForExistence(timeout: 15) else {
            report(title, since: Date(), state: "not-found")
            clearSearch(search)
            return
        }
        open(row, label: title)
        clearSearch(search)
    }

    private func clearSearch(_ search: XCUIElement) {
        let clear = search.buttons["Clear text"]
        if clear.exists { clear.tap() }
        if app.keyboards.buttons["Cancel"].exists { app.keyboards.buttons["Cancel"].tap() }
        else if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
    }

    private func open(_ row: XCUIElement, label: String) {
        let tapped = Date()
        row.tap()
        let state = transcriptState(timeout: 60)
        report(label, since: tapped, state: state)
        // Let any late rendering land before backing out, so the next open is
        // not charged for it.
        sleep(2)
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.waitForExistence(timeout: 10) { back.tap() }
        _ = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] '/Users/'")).firstMatch.waitForExistence(timeout: 30)
    }

    /// Poll the same three named states the screenshot driver does, plus one
    /// more: a query that itself takes seconds is the main thread not turning.
    private func transcriptState(timeout: TimeInterval) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var slowestQuery: TimeInterval = 0
        while Date() < deadline {
            let before = Date()
            let empty = app.staticTexts["Nothing here yet"].exists
            let opening = app.staticTexts["Opening…"].exists
            let loading = app.staticTexts["Loading this conversation…"].exists
            slowestQuery = max(slowestQuery, Date().timeIntervalSince(before))
            if empty { return "empty query=\(ms(slowestQuery))" }
            if !opening && !loading { return "loaded query=\(ms(slowestQuery))" }
            usleep(300_000)
        }
        return "TIMEOUT query=\(ms(slowestQuery))"
    }

    /// Print what the app is actually showing.
    ///
    /// A timeout on its own says only that a row never appeared. It does not
    /// say whether the app is still dialling, has given up with a reason on
    /// screen, or has a machine list it cannot open — and those are three
    /// different bugs. The screen already carries the answer in words a person
    /// would read; this puts those words in the test log.
    private func dumpScreen(_ why: String) {
        print("[PROBE] --- screen dump: \(why) ---")
        for kind in ["staticText", "button"] {
            let query = kind == "staticText" ? app.staticTexts : app.buttons
            for element in query.allElementsBoundByIndex where !element.label.isEmpty {
                print("[PROBE] \(kind): \(element.label.prefix(160))")
            }
        }
        print("[PROBE] --- end screen dump ---")
    }

    private func report(_ what: String, since: Date, state: String) {
        let line = "[PROBE] \(ms(Date().timeIntervalSince(since))) \(state) \"\(what.prefix(48))\""
        print(line)
        XCTContext.runActivity(named: line) { _ in }
    }

    private func ms(_ seconds: TimeInterval) -> String { "\(Int(seconds * 1000))ms" }
}
