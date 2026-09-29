/// What the tunnel does when the network misbehaves.
///
/// Not the happy path — that one announces itself. These are the cases that
/// were shipped broken and found by using the app: a dial that took sixteen
/// seconds because it was serial, a socket that died without telling anyone and
/// left the app confidently showing a stale conversation, a Wi-Fi network the
/// connection should have moved onto and did not.
///
/// Every timing here is compressed. `TunnelTimings` exists for that reason: the
/// shipping silence limit is forty seconds and a suite that waits forty seconds
/// to make one assertion is a suite that stops being run.

import XCTest
@testable import Rowel

final class TunnelTests: XCTestCase {
    private var identity: StaticKeyPair!

    override func setUp() {
        super.setUp()
        identity = .generate()
    }

    // MARK: - Racing

    /// The regression that started all of this. A phone off Wi-Fi used to spend
    /// eight seconds per unreachable local address *before* the relay was
    /// dialled at all, which on cellular is the only address that can work.
    func testAnUnreachableLocalAddressDoesNotDelayTheRelay() async throws {
        let mac = FakeBridle()
        let board = TestSwitchboard()
        board.route("192.168.1.9:61000", to: .blackHole)
        board.route("relay.test:0", to: .machine(mac))

        var timings = TunnelTimings()
        timings.handshake = 30       // The black hole must not be what ends this.
        timings.relayHeadStart = 0.01
        let tunnel = make(bundle: mac.bundle(direct: ["ws://192.168.1.9:61000"]), board: board, timings: timings)

        let started = Date()
        await tunnel.start()
        try await waitForOnline(tunnel)
        let took = Date().timeIntervalSince(started)

        try await expectOnline(tunnel, .relay)
        XCTAssertLessThan(took, 2, "the relay waited for the local address to time out")
        await tunnel.stop()
    }

    /// A short-code claim is refused as `pending` until the person at the Mac
    /// accepts it. That refusal must not be final — the first build that got
    /// it stopped dialling and left the phone on an error while the Mac said
    /// yes.
    func testAClaimWaitingForTheMacKeepsAskingUntilItIsAccepted() async throws {
        let mac = FakeBridle()
        await mac.holdForApproval(times: 2)
        let board = TestSwitchboard()
        board.route("relay.test:0", to: .machine(mac))
        var timings = TunnelTimings()
        timings.approvalPoll = 0.05
        let tunnel = make(bundle: mac.bundle(direct: nil), board: board, timings: timings)

        await tunnel.start()
        try await waitForOnline(tunnel)

        let served = await mac.served.count
        XCTAssertEqual(served, 3, "two pending answers, then the accepted one")
        await tunnel.stop()
    }

    /// Refused is final for a bundle, not for the tunnel: the app rescans and
    /// starts again. The loop used to stay held after a refusal, so `start()`
    /// did nothing and only killing the app recovered.
    func testATunnelThatWasRefusedCanBeStartedAgain() async throws {
        let mac = FakeBridle()
        await mac.refuse(times: 1, reason: "unpaired")
        let board = TestSwitchboard()
        board.route("relay.test:0", to: .machine(mac))
        let tunnel = make(bundle: mac.bundle(direct: nil), board: board, timings: TunnelTimings())

        await tunnel.start()
        try await waitFor("the refusal") {
            if case .refused = await tunnel.status { return true }
            return false
        }
        await tunnel.start()
        try await waitForOnline(tunnel)
        await tunnel.stop()
    }

    /// And the property that ordering used to buy, which the head start has to
    /// keep: at home the relay is not dialled at all.
    func testALocalAddressWinsAndTheRelayIsNeverDialled() async throws {
        let mac = FakeBridle()
        let board = TestSwitchboard()
        board.route("192.168.1.9:61000", to: .machine(mac))
        board.route("relay.test:0", to: .machine(mac))

        var timings = TunnelTimings()
        timings.relayHeadStart = 0.5
        let tunnel = make(bundle: mac.bundle(direct: ["ws://192.168.1.9:61000"]), board: board, timings: timings)

        await tunnel.start()
        try await waitForOnline(tunnel)

        try await expectOnline(tunnel, .lan)
        XCTAssertEqual(board.dialledAddresses, ["192.168.1.9:61000"], "the relay was dialled anyway")
        await tunnel.stop()
    }

    /// A dial that hangs must not hold the connection that already succeeded.
    ///
    /// Measured from a phone's connection log: the relay was up in a second and
    /// the app stayed unusable for three more minutes, because a task group
    /// does not return until every child has and a `send` to an address that
    /// no longer exists ignored cancellation. The winner sat waiting on the
    /// losers. Now every attempt is bounded by closing its own socket, which
    /// nothing can ignore.
    func testAHangingDialDoesNotHoldTheWinner() async throws {
        let mac = FakeBridle()
        let board = TestSwitchboard()
        board.route("relay.test:0", to: .machine(mac))
        // Accepts the connection and then says nothing at all, forever.
        board.route("10.9.9.9:61000", to: .blackHole)

        var timings = TunnelTimings()
        timings.handshake = 1
        timings.relayHeadStart = 0
        let tunnel = make(bundle: mac.bundle(direct: ["ws://10.9.9.9:61000"]), board: board, timings: timings)

        let started = Date()
        await tunnel.start()
        try await waitForOnline(tunnel)
        let took = Date().timeIntervalSince(started)

        // The bound is the handshake timeout, not whatever URLSession would
        // have done with a black hole — which in the field was 198 seconds.
        XCTAssertLessThan(took, 3, "the winner waited \(took)s on a hanging dial")
        await tunnel.stop()
    }

    // MARK: - Liveness

    /// The bug behind "I sent a message and nothing happened". The socket stops
    /// delivering, nobody is told, and the app goes on saying it is connected.
    func testASilentCarrierIsDroppedAndReplaced() async throws {
        let mac = FakeBridle()
        let board = TestSwitchboard()
        board.route("relay.test:0", to: .machine(mac))

        var timings = TunnelTimings()
        timings.silenceLimit = 0.3
        timings.livenessCheck = 0.05
        let tunnel = make(bundle: mac.bundle(direct: nil), board: board, timings: timings)

        await tunnel.start()
        try await waitForOnline(tunnel)
        let first = await mac.handshakes
        XCTAssertEqual(first, 1)

        // Dead in the way that matters: still open, still writable, delivering
        // nothing. Before the watchdog this state lasted until TCP gave up.
        board.carrier(for: "relay.test:0")?.goQuiet()

        try await waitFor("a second handshake") { await mac.handshakes >= 2 }
        try await expectOnline(tunnel, .relay)
        await tunnel.stop()
    }

    /// Reconnecting has to pick up where it stopped, or the watchdog would trade
    /// a stale conversation for a hole in one.
    func testTheReplacementResumesFromTheLastEventSeen() async throws {
        let mac = FakeBridle()
        let board = TestSwitchboard()
        board.route("relay.test:0", to: .machine(mac))

        var timings = TunnelTimings()
        timings.silenceLimit = 0.3
        timings.livenessCheck = 0.05
        let tunnel = make(bundle: mac.bundle(direct: nil), board: board, timings: timings)

        let events = await collectSignals(tunnel)
        await tunnel.start()
        try await waitForOnline(tunnel)

        // The machine pushes on its own end of the pipe; the app end is the
        // one to silence, since that is the side a delivery lands on.
        guard let machineSide = await mac.served.last,
              let appSide = board.carrier(for: "relay.test:0") else { return XCTFail("no carrier") }
        await mac.emit(seq: 41, to: machineSide)
        try await waitFor("the event to be folded") { await events.count >= 1 }

        appSide.goQuiet()
        try await waitFor("a second handshake") { await mac.handshakes >= 2 }
        try await waitFor("a resume") { await mac.resumedFrom.count >= 2 }

        let resumes = await mac.resumedFrom
        XCTAssertEqual(resumes.last, 41, "the reconnect asked for the wrong point in the log")
        // And names the numbering 41 was counted in, so a Bridle that
        // restarted in between cannot pass its own new 42 off as the next.
        let epochs = await mac.resumedEpochs
        XCTAssertEqual(epochs, [mac.epoch, mac.epoch])
        await tunnel.stop()
    }

    /// The Mac's Bridle restarted while the phone was away: a new process,
    /// numbering from 1 again. The app must not resume from its old number in
    /// the new numbering — it refetches, and follows the new process's events.
    func testANewBridleProcessIsARefetchNotAContinuation() async throws {
        let first = FakeBridle()
        let board = TestSwitchboard()
        board.route("relay.test:0", to: .machine(first))
        var timings = TunnelTimings()
        timings.silenceLimit = 0.3
        timings.livenessCheck = 0.05
        let tunnel = make(bundle: first.bundle(direct: nil), board: board, timings: timings)
        let signals = await collectSignals(tunnel)
        await tunnel.start()
        try await waitForOnline(tunnel)
        guard let machineSide = await first.served.last,
              let appSide = board.carrier(for: "relay.test:0") else { return XCTFail("no carrier") }
        await first.emit(seq: 500, to: machineSide)
        try await waitFor("the event") { await signals.count >= 1 }

        // Same keys, new process: a different epoch.
        let restarted = FakeBridle(staticKeys: first.staticKeys)
        board.route("relay.test:0", to: .machine(restarted))
        appSide.goQuiet()
        try await waitFor("a resume to the new process") { await restarted.resumedFrom.count >= 1 }

        let resumed = await restarted.resumedFrom
        XCTAssertEqual(resumed, [0], "the old sequence number was presented to a process that never issued it")
        let refetched = await signals.resyncs
        XCTAssertEqual(refetched, 1, "the app did not refetch after the Bridle restarted")
        await tunnel.stop()
    }

    /// The failure that made reopening the app cost half a minute of dead
    /// taps: iOS suspends the process, quietly kills the socket, and hands
    /// back a connection that *looks* twenty seconds old — too fresh for the
    /// watchdog, dead all the same. `poke` now demands proof of life instead
    /// of waiting out the silence limit.
    func testAPokeOnADeadCarrierForcesAReconnectWithinTheProbeWindow() async throws {
        let mac = FakeBridle()
        let board = TestSwitchboard()
        board.route("relay.test:0", to: .machine(mac))

        var timings = TunnelTimings()
        timings.silenceLimit = 60      // The watchdog must not be what saves this.
        timings.probe = 0.3
        let tunnel = make(bundle: mac.bundle(direct: nil), board: board, timings: timings)

        await tunnel.start()
        try await waitForOnline(tunnel)
        let first = await mac.handshakes
        XCTAssertEqual(first, 1)

        // Suspended-and-resumed: the socket is dead but was alive recently,
        // so silence-based detection has nothing to say for another minute.
        board.carrier(for: "relay.test:0")?.goQuiet()
        await tunnel.poke()

        try await waitFor("the probe to force a second handshake") { await mac.handshakes >= 2 }
        await tunnel.stop()
    }

    /// And the probe must not tear down a connection that answers.
    func testAPokeOnAHealthyCarrierChangesNothing() async throws {
        let mac = FakeBridle()
        let board = TestSwitchboard()
        board.route("relay.test:0", to: .machine(mac))

        var timings = TunnelTimings()
        timings.probe = 0.2
        let tunnel = make(bundle: mac.bundle(direct: nil), board: board, timings: timings)

        await tunnel.start()
        try await waitForOnline(tunnel)
        await tunnel.poke()
        try await Task.sleep(nanoseconds: 600_000_000)

        let handshakes = await mac.handshakes
        XCTAssertEqual(handshakes, 1, "a live carrier was torn down by its own probe")
        try await expectOnline(tunnel, .relay)
        await tunnel.stop()
    }

    // MARK: - Upgrading

    /// Walking in the door should take the connection off the relay, and must
    /// not interrupt it to do so.
    func testWiFiAppearingMovesTheConnectionOffTheRelay() async throws {
        // The ready frame teaches the current addresses, and an empty list
        // means "direct is off" — so a machine with a listener must say so.
        let mac = FakeBridle(direct: ["ws://192.168.1.9:61000"])
        let board = TestSwitchboard()
        board.route("relay.test:0", to: .machine(mac))
        board.route("192.168.1.9:61000", to: .blackHole)

        var timings = TunnelTimings()
        timings.handshake = 0.2
        // The shipping head start, not zero. It *is* the preference for the
        // local path — the upgrade is now a plain reconnect, and what makes
        // that reconnect land on Wi-Fi is the relay starting late. Zeroing it
        // tests a configuration that never ships and makes the race a toss-up.
        timings.relayHeadStart = 0.15
        let tunnel = make(bundle: mac.bundle(direct: ["ws://192.168.1.9:61000"]), board: board, timings: timings)

        await tunnel.start()
        try await waitForOnline(tunnel)
        try await expectOnline(tunnel, .relay)

        // The Mac becomes reachable locally, which is what joining the network
        // means from the app's side.
        board.route("192.168.1.9:61000", to: .machine(mac))
        await tunnel.networkChangedForTesting(onWiFi: true)

        try await waitFor("the switch to the local address") {
            if case .online(.lan, _, _) = await tunnel.status { return true }
            return false
        }
        try await expectOnline(tunnel, .lan)
        await tunnel.stop()
    }

    /// A local address that connects and immediately dies must not be tried
    /// again straight away, or the app spends its life switching.
    func testAnAddressThatFlapsIsLeftAloneForAWhile() async throws {
        // Advertised in ready too: were it not, the learned empty list would
        // remove the candidate on its own and the penalty would pass untested.
        let mac = FakeBridle(direct: ["ws://192.168.1.9:61000"])
        let board = TestSwitchboard()
        board.route("relay.test:0", to: .machine(mac))
        board.route("192.168.1.9:61000", to: .machine(mac))

        var timings = TunnelTimings()
        timings.relayHeadStart = 0.5
        timings.flapWindow = 5
        timings.flapPenalty = 60
        let tunnel = make(bundle: mac.bundle(direct: ["ws://192.168.1.9:61000"]), board: board, timings: timings)

        await tunnel.start()
        try await waitForOnline(tunnel)
        try await expectOnline(tunnel, .lan)

        // Dies well inside the flap window.
        board.carrier(for: "192.168.1.9:61000")?.close("wifi dropped")

        try await waitFor("a fall back to the relay") {
            if case .online(.relay, _, _) = await tunnel.status { return true }
            return false
        }
        try await expectOnline(tunnel, .relay)

        // And it stays off it: an upgrade offered now is declined.
        let before = board.dialledAddresses.filter { $0 == "192.168.1.9:61000" }.count
        await tunnel.networkChangedForTesting(onWiFi: true)
        try await Task.sleep(nanoseconds: 300_000_000)
        let after = board.dialledAddresses.filter { $0 == "192.168.1.9:61000" }.count
        XCTAssertEqual(after, before, "the penalised address was dialled again")
        await tunnel.stop()
    }

    func testTheStatusReportsTheRouteAndUpdatesWhenItSwitches() async throws {
        let mac = FakeBridle(direct: ["ws://192.168.1.9:61000"])
        let board = TestSwitchboard()
        board.route("relay.test:0", to: .machine(mac))
        board.route("192.168.1.9:61000", to: .blackHole)

        var timings = TunnelTimings()
        timings.handshake = 0.2
        timings.relayHeadStart = 0.15
        let tunnel = make(bundle: mac.bundle(direct: ["ws://192.168.1.9:61000"]), board: board, timings: timings)

        // Every status the app sees, which is what the chip renders from.
        let seen = Routes()
        let stream = await tunnel.signals()
        Task {
            for await signal in stream {
                if case .status(.online(let carrier, _, _)) = signal { await seen.add(carrier) }
            }
        }

        await tunnel.start()
        try await waitForOnline(tunnel)
        try await waitFor("the relay to be reported") { await seen.all == [.relay] }

        board.route("192.168.1.9:61000", to: .machine(mac))
        await tunnel.networkChangedForTesting(onWiFi: true)

        try await waitFor("the switch to be reported") { await seen.all == [.relay, .lan] }
        await tunnel.stop()
    }

    /// A Mac that moved while the phone was away must not stay relayed.
    ///
    /// The sequence measured in an office: the stored address is from another
    /// network, so the opening race loses it and the relay wins; the ready
    /// frame then hands over the address that *would* have won. With only a
    /// path change or a foreground return as triggers, nothing asks again —
    /// the app sat on the relay a metre from the Mac for as long as it stayed
    /// open.
    ///
    /// The first version of this test passed without the fix, which made it
    /// worth nothing: it let the harness deliver the fresh address on the very
    /// first dial, so the race found it unaided. The stale address has to
    /// actually win the first round for the question to be asked at all, which
    /// is what `direct(after:)` arranges.
    func testLearningAFreshAddressIsEnoughToLeaveTheRelay() async throws {
        let mac = FakeBridle(direct: ["ws://10.1.151.64:61000"])
        let board = TestSwitchboard()
        board.route("relay.test:0", to: .machine(mac))
        board.route("192.168.110.32:61000", to: .blackHole)
        // Reachable only once the app has been told about it — before that a
        // dial to it is as dead as any address on a network you have left.
        board.route("10.1.151.64:61000", to: .machine(mac))

        var timings = TunnelTimings()
        timings.handshake = 0.2
        timings.relayHeadStart = 0.15
        // The bundle knows only the old address, so the first race is between
        // a black hole and the relay: the relay must win it.
        let tunnel = make(bundle: mac.bundle(direct: ["ws://192.168.110.32:61000"]), board: board, timings: timings)

        // Wi-Fi throughout; the path never changes and the app is never
        // backgrounded, so neither existing trigger can fire. Only the ready
        // frame is new.
        //
        // Read from the status stream rather than by polling: the upgrade is
        // fast enough that a poll can miss the relay entirely, and a test that
        // has to be slower than the code to see what it asserts is a test that
        // will fail on a quick machine for no reason.
        let seen = Routes()
        let stream = await tunnel.signals()
        Task {
            for await signal in stream {
                if case .status(.online(let carrier, _, _)) = signal { await seen.add(carrier) }
            }
        }
        await tunnel.networkChangedForTesting(onWiFi: true)
        await tunnel.start()

        try await waitFor("the relay first, then the address it was taught") {
            await seen.all == [.relay, .lan]
        }
        XCTAssertTrue(
            board.dialledAddresses.contains("10.1.151.64:61000"),
            "the learned address was never dialled: \(board.dialledAddresses)"
        )
        // And the learned list replaces the stale one rather than joining it:
        // an address from a network the phone has left is never dialled twice.
        XCTAssertEqual(
            board.dialledAddresses.filter { $0 == "192.168.110.32:61000" }.count, 1,
            "the stale address was dialled again after the machine taught a new one"
        )
        await tunnel.stop()
    }

    // MARK: - Reachability

    /// A local address on a network this device is not on is not dialled.
    ///
    /// The app used to ask "are we on Wi-Fi", which is the wrong question in
    /// both directions: on cellular it dialled addresses that could not answer,
    /// and a Mac tethered to this very phone — whose own path is cellular —
    /// would have been refused a dial to a machine one hop away. Asking whether
    /// the address is inside one of our subnets answers both cases with one
    /// fact, and lets the relay start at once when there is no local runner.
    func testOnlyAddressesOnOurNetworkAreDialled() async throws {
        let mac = FakeBridle(direct: ["ws://192.168.1.9:61000"])
        let board = TestSwitchboard()
        board.route("relay.test:0", to: .machine(mac))
        board.route("192.168.1.9:61000", to: .machine(mac))

        var timings = TunnelTimings()
        // Long enough that the relay could not win a race it was made to wait
        // for: if the local address were dialled, this test would time out.
        timings.relayHeadStart = 30
        let tunnel = make(
            bundle: mac.bundle(direct: ["ws://192.168.1.9:61000"]),
            board: board,
            timings: timings,
            onOurNetwork: { _ in false }
        )

        await tunnel.start()
        try await waitForOnline(tunnel)

        try await expectOnline(tunnel, .relay)
        XCTAssertEqual(
            board.dialledAddresses, ["relay.test:0"],
            "an address on no network of ours was dialled anyway"
        )
        await tunnel.stop()
    }

    /// And the check itself: it must refuse only what it can prove, since a
    /// false negative hides a working path while a false positive costs one
    /// failed connect.
    func testTheNetworkCheckRefusesOnlyWhatItCanProve() {
        // TEST-NET-3, reserved for documentation and on nobody's LAN.
        XCTAssertFalse(isOnOurNetwork(URL(string: "ws://203.0.113.1:61000/v1/tunnel")!))
        // Not an IPv4 literal, so not judgeable — a tailnet name, an operator's
        // tunnel hostname. Dialled rather than discarded.
        XCTAssertTrue(isOnOurNetwork(URL(string: "ws://my-mac.tailnet.ts.net:61000/v1/tunnel")!))
        // Loopback is reachable by definition and must survive the filter, or
        // the e2e suite loses its direct path.
        XCTAssertTrue(isOnOurNetwork(URL(string: "ws://127.0.0.1:61000/v1/tunnel")!))
    }

    // MARK: - Helpers

    private func make(
        bundle: PairingBundle,
        board: TestSwitchboard? = nil,
        timings: TunnelTimings,
        // The addresses here are fictional and would not match whatever
        // subnets the machine running the suite happens to be on, so the
        // real check is replaced. `testOnlyAddressesOnOurNetworkAreDialled`
        // exercises the filtering itself.
        onOurNetwork: @escaping @Sendable (URL) -> Bool = { _ in true }
    ) -> Tunnel {
        let board = board ?? {
            let fresh = TestSwitchboard()
            return fresh
        }()
        return Tunnel(
            bundle: bundle,
            identity: identity,
            deviceName: "iPhone",
            clientVersion: "test",
            pairingToken: nil,
            open: board.opener,
            onOurNetwork: onOurNetwork,
            watchNetwork: false,
            timings: timings
        )
    }

    /// Assert the settled status by waiting for it, never by sampling.
    ///
    /// Sampling was the bug. Every one of these assertions used to read
    /// `tunnel.status` into a local and compare the whole value, and the value
    /// has a legitimate two-step transition — so roughly one run in five caught
    /// it mid-step and failed on a `harnessUp` that was about to be true. It hit
    /// a different test each time, because which test loses the race is a matter
    /// of scheduling. Waiting for the state you mean cannot observe the state
    /// before it.
    /// - Parameters:
    ///   - tunnel: the tunnel under test.
    ///   - carrier: the path it must have settled on.
    private func expectOnline(
        _ tunnel: Tunnel,
        _ carrier: Carrier,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await waitFor("the tunnel to settle online over \(carrier)", file: file, line: line) {
            await tunnel.status == .online(carrier: carrier, machine: "a-mac", harnessUp: true)
        }
    }

    /// Wait for online *and settled*, which are not the same instant.
    ///
    /// The handshake reply carries the machine name, so the tunnel goes online
    /// the moment it lands — with `harnessUp: false`, because whether dsh
    /// answers is not known until the ready frame arrives a moment later. That
    /// window is real and correct, and a wait that returns inside it hands the
    /// test a half-built status: this caught
    /// `testWiFiAppearingMovesTheConnectionOffTheRelay` once in five runs,
    /// asserting `harnessUp: true` against a value that was about to be true.
    ///
    /// The fake always reports dsh reachable, so waiting for `harnessUp` is
    /// waiting for the ready frame — the second step, by the only part of the
    /// status that distinguishes it.
    private func waitForOnline(_ tunnel: Tunnel) async throws {
        try await waitFor("the tunnel to come online") {
            if case .online(_, _, true) = await tunnel.status { return true }
            return false
        }
    }

    /// - Parameters:
    ///   - what: named in the failure, so a timeout says what never happened.
    ///   - timeout: how long to keep asking.
    ///   - file: the caller, so the failure lands on the assertion and not here.
    ///   - line: likewise.
    ///   - condition: polled until true.
    private func waitFor(
        _ what: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }

    private func collectSignals(_ tunnel: Tunnel) async -> Counter {
        let counter = Counter()
        let stream = await tunnel.signals()
        Task {
            for await signal in stream {
                if case .event = signal { await counter.bump() }
                if case .resync = signal { await counter.bumpResync() }
            }
        }
        return counter
    }
}

/// The carriers the app was told about, in order.
actor Routes {
    private(set) var all: [Carrier] = []
    func add(_ carrier: Carrier) {
        if all.last != carrier { all.append(carrier) }
    }
}

/// Somewhere for the signal task to put what it saw.
actor Counter {
    private(set) var count = 0
    private(set) var resyncs = 0
    func bump() { count += 1 }
    func bumpResync() { resyncs += 1 }
}

// MARK: - Being woken

extension TunnelTests {
    /// The machine has to be told where to ring, and told again every time the
    /// tunnel is rebuilt — which is several times a day. A token handed over
    /// once would only work until the next reconnect, and the failure is
    /// silent: nothing errors, the push simply never arrives.
    func testTheTokenIsOfferedAgainOnEveryReconnect() async throws {
        let mac = FakeBridle()
        let board = TestSwitchboard()
        board.route("relay.test:0", to: .machine(mac))

        var timings = TunnelTimings()
        timings.silenceLimit = 0.3
        timings.livenessCheck = 0.05
        let tunnel = make(bundle: mac.bundle(direct: nil), board: board, timings: timings)

        await tunnel.start()
        try await expectOnline(tunnel, .relay)
        await tunnel.offerWake(token: "abc123")
        try await waitFor("the machine to be told where to ring") { await mac.wakes.count == 1 }

        // The socket dies the way they actually die: still open, delivering
        // nothing, until the watchdog replaces it.
        board.carrier(for: "relay.test:0")?.goQuiet()
        try await waitFor("a second handshake") { await mac.handshakes >= 2 }
        try await waitFor("the new tunnel to say it again") { await mac.wakes.count >= 2 }

        let seen = await mac.wakes
        XCTAssertEqual(seen.last, "abc123")
        await tunnel.stop()
    }

    /// Turning notifications off has to reach the machine, or it goes on
    /// ringing a phone that will not show the banner.
    func testWithdrawingTheTokenIsSent() async throws {
        let mac = FakeBridle()
        let board = TestSwitchboard()
        board.route("relay.test:0", to: .machine(mac))
        let tunnel = make(bundle: mac.bundle(direct: nil), board: board, timings: TunnelTimings())

        await tunnel.start()
        try await expectOnline(tunnel, .relay)
        await tunnel.offerWake(token: "abc123")
        try await waitFor("the token") { await mac.wakes.count == 1 }
        await tunnel.offerWake(token: String?.none)
        try await waitFor("the withdrawal") { await mac.wakes.count == 2 }

        let seen = await mac.wakes
        XCTAssertEqual(seen.last, String?.none, "the machine was never told to stop")
        await tunnel.stop()
    }

    /// Silence before iOS answers, because a nil sent then does not mean "stop
    /// ringing me" — it means "I have not asked yet", and the machine cannot
    /// tell the two apart. Sending it would retract a token from a previous
    /// launch that is still perfectly good.
    func testNothingIsSentBeforeTheSystemAnswers() async throws {
        let mac = FakeBridle()
        let board = TestSwitchboard()
        board.route("relay.test:0", to: .machine(mac))
        let tunnel = make(bundle: mac.bundle(direct: nil), board: board, timings: TunnelTimings())

        await tunnel.start()
        try await expectOnline(tunnel, .relay)
        try await Task.sleep(nanoseconds: 200_000_000)
        let seen = await mac.wakes
        XCTAssertTrue(seen.isEmpty, "offered a token nobody had asked iOS for yet")
        await tunnel.stop()
    }

    /// The same value twice is not worth a frame; a changed one is.
    func testOnlyChangesAreSent() async throws {
        let mac = FakeBridle()
        let board = TestSwitchboard()
        board.route("relay.test:0", to: .machine(mac))
        let tunnel = make(bundle: mac.bundle(direct: nil), board: board, timings: TunnelTimings())

        await tunnel.start()
        try await expectOnline(tunnel, .relay)
        await tunnel.offerWake(token: "abc123")
        try await waitFor("the token") { await mac.wakes.count == 1 }
        await tunnel.offerWake(token: "abc123")
        try await Task.sleep(nanoseconds: 150_000_000)
        let repeated = await mac.wakes.count
        XCTAssertEqual(repeated, 1, "said the same thing twice")

        // A reinstall mints a new token, and the machine has to hear about it.
        await tunnel.offerWake(token: "def456")
        try await waitFor("the new token") { await mac.wakes.count == 2 }
        let latest = await mac.wakes.last
        XCTAssertEqual(latest, "def456")
        await tunnel.stop()
    }
}
