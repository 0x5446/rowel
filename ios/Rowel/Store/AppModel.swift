/// The root of the app's state.
///
/// Owns the device identity, the list of paired machines, and the one machine
/// currently connected. One tunnel at a time on purpose: a phone that holds a
/// socket per machine wakes the radio per machine, and the case for several at
/// once — watching two Macs at the same moment — is rarer than the battery cost.
/// Switching machines is a disconnect and a connect, and both are fast.

import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

@MainActor
@Observable
public final class AppModel {
    /// Every machine this device has paired with, most recently added first.
    public private(set) var machines: [PairedMachine] = []
    /// The machine currently connected, if any.
    public private(set) var active: MachineSession?
    /// Set when the identity could not be created or read; the app is unusable
    /// until it clears, so it gets a screen of its own rather than a banner.
    public private(set) var fatal: String?
    /// What this device calls itself on a machine's paired list.
    public var deviceName: String {
        didSet {
            defaults.set(deviceName, forKey: Keys.deviceName)
            active?.rename(device: deviceName)
        }
    }

    /// True until the person has paired anything, which selects the welcome flow.
    public var isNew: Bool { machines.isEmpty }

    public let notifier: Notifier
    /// Where iOS says this phone can be reached; see `Push.swift`.
    public let push: PushRegistrar
    public let clientVersion: String

    private var identity: StaticKeyPair?
    private let defaults: UserDefaults
    private var pairingTokens: [String: String] = [:]

    private enum Keys {
        static let machines = "rowel.machines.v1"
        static let deviceName = "rowel.deviceName"
        static let lastMachine = "rowel.lastMachine"
    }

    public init(defaults: UserDefaults = .standard, clientVersion: String? = nil, notifier: Notifier? = nil) {
        self.defaults = defaults
        self.clientVersion = clientVersion ?? AppModel.bundleVersion
        self.notifier = notifier ?? Notifier()
        self.push = PushDelegate.registrar
        deviceName = defaults.string(forKey: Keys.deviceName) ?? AppModel.defaultDeviceName
        #if DEBUG
        // A UI test seam. The welcome flow only exists for a device that has
        // never paired, and a test machine has usually paired already; without
        // this the one screen every new user sees is the one screen that can
        // never be tested.
        if ProcessInfo.processInfo.environment["ROWEL_UITEST_FRESH"] == "1" {
            defaults.removeObject(forKey: Keys.machines)
            defaults.removeObject(forKey: Keys.lastMachine)
        }
        #endif
        machines = AppModel.loadMachines(defaults)
        loadIdentity()
        // Last, because the closure captures self and everything stored has to
        // exist before it can. iOS answers whenever it likes, usually long
        // before any machine is connected, so the answer is kept and handed to
        // whichever session exists at the time rather than delivered to one
        // that has to be there to catch it.
        push.onAnswer = { [weak self] token in
            guard let self, let session = self.active else { return }
            self.offer(token: token, to: session)
        }
    }

    /// Read the identity, or record why it could not be read.
    ///
    /// Separate from `init` because this is worth trying more than once. The key
    /// is stored `afterFirstUnlockThisDeviceOnly`, so a launch that beats the
    /// first unlock of the day fails with `errSecInteractionNotAllowed` and then
    /// succeeds seconds later — treating the first answer as final would strand
    /// the app on an error screen for a condition that has already cleared.
    private func loadIdentity() {
        do {
            identity = try DeviceIdentity.load()
            fatal = nil
        } catch {
            fatal = "Rowel couldn’t read this iPhone’s identity. \(error.localizedDescription)"
        }
    }

    /// Try the identity again, from the error screen.
    public func retryIdentity() {
        guard identity == nil else { fatal = nil; return }
        loadIdentity()
        if fatal == nil { restoreLastConnection() }
    }

    // MARK: - Connection

    /// Connect to a machine, disconnecting whatever was connected before.
    ///
    /// - Parameter fresh: rebuild the session even when this machine is the one
    ///   already connected. A new pairing bundle — a rescan after the Mac
    ///   refused this phone, or after its key changed — is only read when a
    ///   session is built, so reusing the old one ignored it.
    public func connect(to machineId: String, fresh: Bool = false) {
        guard let identity else { return }
        if !fresh, active?.machine.id == machineId, let status = active?.status, status.isLive { return }
        active?.stop()
        guard let machine = machines.first(where: { $0.id == machineId }) else {
            active = nil
            return
        }
        defaults.set(machineId, forKey: Keys.lastMachine)
        let session = MachineSession(
            machine: machine,
            identity: identity,
            deviceName: deviceName,
            clientVersion: clientVersion,
            pairingToken: pairingTokens.removeValue(forKey: machineId),
            notifier: notifier
        )
        // The machine tells every connection where it can be dialled directly
        // *now*. Persisted so the next cold start dials the Mac where it is,
        // not where it was on pairing day — a Mac that moved to a hotspot or
        // an office network would otherwise be relay-only forever.
        // Told once here and again on every later answer. The tunnel re-sends
        // it on each `ready` of its own accord, because the machine is what
        // stores it and a tunnel is replaced several times a day.
        if push.answered { offer(token: push.token, to: session) }
        session.learnedDirect = { [weak self] addresses in
            guard let self, let index = self.machines.firstIndex(where: { $0.id == machineId }) else { return }
            guard self.machines[index].direct != addresses else { return }
            self.machines[index].direct = addresses
            self.persist()
        }
        active = session
        session.start()
    }

    /// Reconnect to whatever was open last time the app ran.
    public func restoreLastConnection() {
        guard active == nil else { return }
        let last = defaults.string(forKey: Keys.lastMachine)
        if let last, machines.contains(where: { $0.id == last }) {
            connect(to: last)
        } else if let first = machines.first {
            connect(to: first.id)
        }
    }

    public func disconnect() {
        active?.stop()
        active = nil
    }

    // MARK: - Pairing

    /// Accept a pairing bundle from a QR, a deep link, or a claimed short code.
    ///
    /// Re-pairing a machine already on the list replaces its addresses rather
    /// than adding a duplicate — running `bridle pair` again after moving house
    /// is exactly how someone updates a stale LAN address.
    public func pair(with bundle: PairingBundle) {
        var machine = PairedMachine(bundle: bundle)
        if let index = machines.firstIndex(where: { $0.id == bundle.device }) {
            // The merge rule lives on PairedMachine — see `absorbing` for why
            // the phone's name survives and the wire facts do not.
            machine = machines[index].absorbing(bundle)
            machines[index] = machine
        } else {
            machines.insert(machine, at: 0)
        }
        if !bundle.token.isEmpty {
            pairingTokens[bundle.device] = bundle.token
        }
        persist()
        connect(to: machine.id, fresh: true)
        Task {
            // Ask first: registering without permission yields a token that can
            // wake nothing, and the machine would ring it for as long as the
            // pairing lasted. `refresh` then reads the answer back out of the
            // system rather than trusting the return value, which is the same
            // path every later launch takes.
            await notifier.requestPermission()
            await push.refresh()
        }
    }

    private func offer(token: String?, to session: MachineSession) {
        Task { await session.tunnel.offerWake(token: token) }
    }

    /// Bring iOS, this app and the machine back into agreement about push.
    ///
    /// Called at launch and on every return to the foreground. Doing it only at
    /// pairing was the feature quietly not working at all for anyone who had
    /// already paired, and gave someone who refused the prompt no second
    /// chance after allowing it in Settings.
    public func refreshPush() {
        guard !machines.isEmpty else { return }
        Task { await push.refresh() }
    }

    /// Claim a typed short code and pair with what comes back.
    public func pair(shortCode code: String, relay: String = defaultRelayURL) async throws {
        let bundle = try await RelayDirectory(base: relay).claim(code: code)
        pair(with: bundle)
    }

    /// Handle a `rowel://pair#…` link.
    @discardableResult
    public func open(url: URL) -> Bool {
        guard let bundle = try? Pairing.decodeLink(url.absoluteString) else { return false }
        pair(with: bundle)
        return true
    }

    /// Forget a machine on this device.
    ///
    /// This is one-sided: the Mac still lists this iPhone until someone runs
    /// `bridle revoke` there. Saying so plainly beats implying a remote effect
    /// the app cannot deliver — the tunnel is the only channel, and a phone that
    /// wants to be forgotten cannot be trusted to ask on its own behalf.
    public func unpair(_ machineId: String) {
        if active?.machine.id == machineId { disconnect() }
        machines.removeAll { $0.id == machineId }
        pairingTokens[machineId] = nil
        persist()
        if defaults.string(forKey: Keys.lastMachine) == machineId {
            defaults.removeObject(forKey: Keys.lastMachine)
        }
        restoreLastConnection()
    }

    /// What to call a machine on screen, collision-aware. See `MachineLabel`.
    public func label(for machine: PairedMachine) -> MachineLabel {
        MachineLabel.resolve(machine, among: machines)
    }

    /// Rename a machine as it appears in this app.
    public func rename(machine machineId: String, to name: String) {
        guard let index = machines.firstIndex(where: { $0.id == machineId }) else { return }
        machines[index].name = name
        persist()
    }

    /// Throw away this device's identity and every pairing.
    ///
    /// The Keychain entry goes with it, so the next launch generates a new key
    /// and every machine treats this phone as one it has never seen.
    public func resetEverything() {
        disconnect()
        machines = []
        pairingTokens = [:]
        defaults.removeObject(forKey: Keys.machines)
        defaults.removeObject(forKey: Keys.lastMachine)
        try? DeviceIdentity.reset()
        identity = try? DeviceIdentity.load()
    }

    /// This device's own key fingerprint, to compare against `bridle devices`.
    public var deviceFingerprint: String {
        guard let identity else { return "unavailable" }
        return Pairing.keyFingerprint(identity.publicKey)
    }

    // MARK: - Lifecycle

    /// The app came to the front: stop posting notifications and reconnect now
    /// rather than waiting out a backoff that started while it was suspended.
    public func enteredForeground() {
        notifier.foreground = true
        // Coming back to the front is the most likely moment for a Keychain that
        // refused a pre-unlock read to start answering, so take the free retry
        // rather than making the person tap the button.
        if identity == nil { retryIdentity() }
        active?.poke()
    }

    public func enteredBackground() {
        notifier.foreground = false
    }

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(machines) else { return }
        defaults.set(data, forKey: Keys.machines)
    }

    private static func loadMachines(_ defaults: UserDefaults) -> [PairedMachine] {
        guard let data = defaults.data(forKey: Keys.machines) else { return [] }
        return (try? JSONDecoder().decode([PairedMachine].self, from: data)) ?? []
    }

    static var defaultDeviceName: String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return "iPhone"
        #endif
    }

    public static var bundleVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "rowel-ios/\(short) (\(build))"
    }
}
