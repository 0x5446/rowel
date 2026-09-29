/// Scanning a machine's code again has to take effect.
///
/// The screen for a Mac that refused this phone says "run `bridle pair` and
/// scan the new code". Doing so updated the stored bundle and then reused the
/// session already built from the old one, which kept its refused state — so
/// the instruction on screen could not work, and only killing the app did.

import XCTest
@testable import Rowel

@MainActor
final class RepairTests: XCTestCase {
    private let suiteName = "rowel.tests.repair"

    func testScanningTheSameMachineAgainBuildsAFreshSession() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        suite.removePersistentDomain(forName: suiteName)
        defer { suite.removePersistentDomain(forName: suiteName) }
        let model = AppModel(defaults: suite, clientVersion: "rowel-tests/1", notifier: Notifier(center: nil))
        try XCTSkipIf(model.fatal != nil, "no device identity in this test host: \(model.fatal ?? "")")
        let bundle = PairingBundle(
            relay: "wss://relay.invalid",
            device: "device-repair",
            key: StaticKeyPair.generate().publicKey.base64urlString,
            token: "first",
            name: "Mac"
        )

        model.pair(with: bundle)
        let first = try XCTUnwrap(model.active)
        model.pair(with: PairingBundle(relay: bundle.relay, device: bundle.device, key: bundle.key, token: "second", name: "Mac"))
        let second = try XCTUnwrap(model.active)

        XCTAssertFalse(first === second, "the rescanned bundle was ignored in favour of the old session")
        model.disconnect()
    }
}
