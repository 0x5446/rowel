/// Asking iOS where this phone can be reached, and telling the machine.
///
/// The notifications in `Notifier` are posted by this app while it holds a
/// tunnel, which covers someone already looking at their phone and nothing
/// else. iOS suspends a backgrounded app within minutes and the tunnel goes
/// with it, so every question the agent asks after that reaches a machine
/// waiting on a person who was never told. Being elsewhere is the premise of
/// the product, so that is the common case.
///
/// The token goes to the paired machine inside the Noise channel. The Relay is
/// handed it one wake at a time, at the moment a push is sent, and is never
/// told what the push is about — the words in the banner come from a constant
/// on the Relay, and the real ones appear once the person opens the app and it
/// reconnects.
///
/// No APNs environment is worked out here. The first version read
/// `aps-environment` out of the app's own embedded provisioning profile and
/// passed the answer down through every layer, which is a guess dressed as a
/// fact: a Release build signed for development is a sandbox token wearing a
/// production badge, and both directions of that mistake fail identically —
/// nothing delivered, no error anywhere. Apple answers the question itself by
/// refusing the wrong host, so the Relay tries both and nobody has to guess.

import Foundation
import UIKit
import UserNotifications

/// Holds the device token iOS hands back, for whoever is connected at the time.
///
/// A separate object because the two events have nothing to do with each other:
/// iOS answers whenever it feels like it, often before any machine is
/// connected, and a tunnel is established and torn down several times a day
/// afterwards.
@MainActor
public final class PushRegistrar {
    /// The token, or nil while iOS has not answered.
    public private(set) var token: String?
    /// Whether iOS has answered at all — a `nil` token before it has is "not
    /// asked yet", which is a different thing from "do not ring me".
    public private(set) var answered = false

    /// Called on every answer, so whoever is connected can pass it on.
    public var onAnswer: ((String?) -> Void)?

    /// Injectable so a test does not need a real notification centre.
    private let authorized: @Sendable () async -> Bool
    private let ask: @MainActor () -> Void

    /// - Parameters:
    ///   - authorized: whether notifications may currently be posted.
    ///   - ask: hands the request to the system.
    public init(
        authorized: (@Sendable () async -> Bool)? = nil,
        ask: (@MainActor () -> Void)? = nil,
    ) {
        self.authorized = authorized ?? {
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            // `.notDetermined` is nobody having been asked yet, which is not a
            // refusal — the pairing flow asks, and until then there is nothing
            // to register and nothing to withdraw.
            return status != .denied && status != .notDetermined
        }
        self.ask = ask ?? { UIApplication.shared.registerForRemoteNotifications() }
    }

    /// Bring the machine's idea of this phone up to date.
    ///
    /// Called at every launch and every return to the foreground, not once at
    /// pairing. Registering only at pairing was the whole feature quietly not
    /// working: a phone that paired before this shipped never registers, and
    /// someone who refuses the prompt and later allows it in Settings never
    /// gets a second chance. Neither failure says anything — the app looks
    /// fine and simply never buzzes.
    public func refresh() async {
        if await authorized() {
            ask()
            return
        }
        // Explicitly switched off in Settings. This is the trigger the
        // withdrawal path exists for; without it the machine goes on ringing a
        // phone that shows nothing.
        withdraw()
    }

    /// iOS answered.
    /// - Parameter data: the raw token bytes.
    public func accept(_ data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        answered = true
        guard hex != token else { return }
        token = hex
        onAnswer?(hex)
    }

    /// iOS could not issue a token.
    ///
    /// The token already on the machine is left alone. Registration fails for
    /// reasons that have nothing to do with the phone still being reachable —
    /// no network at launch is the common one — and an earlier version treated
    /// that as "stop ringing me", deleting a perfectly good address on the Mac
    /// because the phone happened to boot in a lift.
    public func failed() {
        answered = true
    }

    /// Notifications are off. Tell the machine to stop.
    ///
    /// Announced whenever the system says no, not only when this object
    /// remembers handing a token out. The token lives in memory and the machine
    /// keeps it on disk, so after a relaunch the two disagree: `token` is nil
    /// again while the Mac still holds one and goes on ringing a phone that
    /// shows nothing. Guarding on `token != nil` meant the withdrawal fired
    /// exactly once — in the session where notifications were switched off —
    /// and never again, which is the session least likely to be running.
    ///
    /// Saying it twice is free: the Bridle drops a withdrawal for a peer that
    /// has no token.
    private func withdraw() {
        answered = true
        token = nil
        onAnswer?(nil)
    }
}

/// The delegate that exists only to receive the token.
///
/// SwiftUI has no other way to see `didRegisterForRemoteNotifications`: it is
/// an `UIApplicationDelegate` callback and there is no `onReceive` for it.
///
/// The registrar it forwards to is created here and read by the model, rather
/// than assigned into a nil slot by a view task. The other way round, a token
/// that arrived before the view ran was dropped on the floor with nothing to
/// say so.
public final class PushDelegate: NSObject, UIApplicationDelegate {
    /// Created before anything can call back into it.
    @MainActor public static let registrar = PushRegistrar()

    public func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data,
    ) {
        Task { @MainActor in PushDelegate.registrar.accept(deviceToken) }
    }

    public func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error,
    ) {
        Task { @MainActor in PushDelegate.registrar.failed() }
    }
}
