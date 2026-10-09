/// What a conversation looks like in the instant after it is opened.
///
/// The transcript has three things it can say when it has no messages to draw:
/// it is opening, it is loading, or there is nothing here. Only the third is a
/// statement about the conversation; the other two are about the app. Getting
/// that wrong is not a crash and no test caught it — the conversation filled in
/// a moment later and the wrong answer was gone before it could be read.
///
/// It was still wrong. Every conversation opened by telling the person it was
/// empty, and the screenshot driver — which cannot tell a flicker from a fact —
/// believed it and wrote a store listing full of empty screens.

import XCTest
@testable import Rowel

/// A transport that never answers, so the window under test stays open.
private actor SilentTransport: CallOnlyTransport {
    func call(_ method: String, _ payload: JSONValue) async throws -> JSONValue {
        // Long enough that the assertions run inside the gap a real network
        // would leave, rather than racing a stub that replies instantly.
        try await Task.sleep(for: .seconds(30))
        return .emptyObject
    }
}

@MainActor
final class OpeningTests: XCTestCase {
    private var suite: UserDefaults!
    private let suiteName = "rowel.tests.opening"

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: suiteName)
        suite.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func machine() -> MachineSession {
        let bundle = PairingBundle(
            relay: "https://relay.invalid",
            device: "device-1",
            key: "",
            token: "",
            name: "Test Mac"
        )
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

    func testAConversationIsLoadingFromTheMomentItExists() {
        let session = machine()

        // Synchronously — no `await`, no yield. `loadHistory` sets this too, but
        // it runs in a Task, and the view can render before that Task is
        // scheduled. The gap is what the person saw.
        let conversation = session.conversation("s1")

        XCTAssertTrue(conversation.loading,
                      "a conversation that has not fetched anything yet is loading, not empty")
        XCTAssertTrue(conversation.items.isEmpty, "and it has nothing to show yet")
    }

    func testTheEmptyStateOnlySpeaksForAConversationThatFinishedLoading() async {
        let session = machine()
        let conversation = session.conversation("s1")
        XCTAssertTrue(conversation.loading)

        // The empty state is shown when `items.isEmpty && !loading`, so this is
        // the exact condition the view draws on. It has to be false here: the
        // answer is not in yet, and saying "nothing here yet" would be a claim
        // the app cannot support.
        XCTAssertFalse(conversation.items.isEmpty && !conversation.loading,
                       "the empty state must not be reachable before history answers")
    }
}
