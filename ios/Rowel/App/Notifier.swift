/// Local notifications for the moments worth interrupting someone over.
///
/// Three, and only three: a tool is asking permission, the agent is asking a
/// question, and a long turn finished. Everything else the agent does is visible
/// when you look, and a notification for each would train people to ignore all of
/// them.
///
/// These are LOCAL notifications, posted by the app while it holds a live
/// tunnel — which is the case where someone is already looking at their phone,
/// and the words in them are the real ones because they never left the device.
///
/// A suspended app holds no tunnel and posts nothing, and that gap is what
/// `Push.swift` covers: the machine has the Relay ring this phone with a fixed
/// banner. The push does not run the app — nothing happens until the person
/// opens it, and then it reconnects and shows the request itself. The banner
/// carries a fixed sentence and no detail, so the third party in the path is
/// still never told that your agent wants to run `rm`.

import Foundation
import UserNotifications

@MainActor
public final class Notifier {
    /// Suppressed while the app is in front — a banner over the screen already
    /// showing the request is just noise.
    public var foreground = true

    private var lastFinish: [String: Date] = [:]
    private let center: UNUserNotificationCenter?

    public init(center: UNUserNotificationCenter?) {
        self.center = center
    }

    /// The real one. Tests build a `Notifier(center: nil)`, which posts nothing.
    public convenience init() {
        self.init(center: .current())
    }

    /// Ask once, at the moment the first machine pairs — not at launch, where
    /// the question has no context and gets refused.
    /// - Returns: whether notifications may now be posted, which also decides
    ///   whether it is worth asking iOS for a push token.
    @discardableResult
    public func requestPermission() async -> Bool {
        guard let center else { return false }
        return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    public func approval(_ request: ApprovalRequest, machine: String, title: String) {
        guard !foreground else { return }
        post(
            id: "approval-\(request.approvalId)",
            title: "\(request.toolName) needs permission",
            body: "\(title) on \(machine)",
            interruption: .timeSensitive
        )
    }

    public func question(_ request: QuestionRequest, machine: String, title: String) {
        guard !foreground else { return }
        post(
            id: "question-\(request.id)",
            title: request.items.first?.question ?? "The agent has a question",
            body: "\(title) on \(machine)",
            interruption: .timeSensitive
        )
    }

    /// A turn ended. Rate-limited per session: an agent that runs a dozen short
    /// turns in a row should buzz once, not a dozen times.
    public func finished(machine: String, title: String) {
        guard !foreground else { return }
        let now = Date()
        if let last = lastFinish[title], now.timeIntervalSince(last) < 60 { return }
        lastFinish[title] = now
        post(id: "done-\(title.hashValue)", title: "Finished", body: "\(title) on \(machine)", interruption: .active)
    }

    private func post(id: String, title: String, body: String, interruption: UNNotificationInterruptionLevel) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = interruption
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
