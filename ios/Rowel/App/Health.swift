/// What the system saw go wrong, kept for the person to hand over.
///
/// Field report: "it just froze", seven seconds after launch, the crash dialog,
/// the feedback arrived at App Store Connect — and the crash log did not. The
/// app itself had no record of anything: there is no crash reporter by design,
/// and the connection log lives in memory and dies with the process. A bug
/// with a witness and no testimony.
///
/// MetricKit is how to have testimony without adding a reporter. The OS keeps
/// the hang and crash diagnostics it already produces — call stacks, the
/// terminating signal, how long the main thread was stuck — and hands them to
/// the app on a later launch. Nothing here transmits anything. Reports are
/// written to Application Support and listed in Diagnostics with a share
/// button, and leave the phone only when a person sends one.

import Foundation
import Observation
#if canImport(MetricKit) && os(iOS)
import MetricKit
#endif

/// One delivered diagnostic payload, on disk.
public struct HealthReport: Identifiable, Equatable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let receivedAt: Date
    public let hangs: Int
    public let crashes: Int
    /// Launches the OS judged too slow — the seven-second kind.
    public let slowLaunches: Int
    /// One line a person can read in a list: "1 hang (6 s)", "crash: SIGKILL".
    public let headline: String
}

/// Receives the OS's diagnostics for this app and keeps them.
@MainActor
@Observable
public final class Health {
    public private(set) var reports: [HealthReport] = []
    private let directory: URL
    /// The subscriber object the OS holds a reference to. Kept here so it
    /// lives as long as this does.
    private var subscriber: AnyObject?
    /// How many to keep. Each is a few KB; the point is the recent ones.
    private static let keep = 30

    /// - Parameter directory: where reports live. Defaults to Application
    ///   Support; tests pass a temporary one.
    public init(directory: URL? = nil) {
        self.directory = directory ?? Health.defaultDirectory()
        reload()
    }

    /// Ask the OS to deliver diagnostics. Idempotent.
    ///
    /// Delivery is on the OS's schedule: a crash or hang from this run arrives
    /// on a later launch, sometimes the next day. That is why the list says
    /// "received", not "happened".
    public func start() {
        #if canImport(MetricKit) && os(iOS)
        guard subscriber == nil else { return }
        let bridge = MetricBridge { [weak self] data in
            Task { @MainActor in self?.record(data) }
        }
        MXMetricManager.shared.add(bridge)
        subscriber = bridge
        #endif
    }

    /// Re-read the directory. The list on screen follows.
    public func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        reports = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> HealthReport? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
                return Health.summarize(data, receivedAt: stamp, url: url)
            }
            .sorted { $0.receivedAt > $1.receivedAt }
    }

    /// Keep one payload. Called for each the OS delivers.
    public func record(_ data: Data) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "metrickit-\(Health.stamp.string(from: Date())).json"
        let url = directory.appendingPathComponent(name)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        reload()
        // Oldest past the cap go. `reports` is newest-first.
        for stale in reports.dropFirst(Health.keep) {
            try? FileManager.default.removeItem(at: stale.url)
        }
        if reports.count > Health.keep { reload() }
    }

    public func remove(_ report: HealthReport) {
        try? FileManager.default.removeItem(at: report.url)
        reload()
    }

    /// Read what matters off a payload without depending on every key.
    ///
    /// The JSON is MetricKit's own `jsonRepresentation()`, whose shape has
    /// shifted between iOS releases. Counting the arrays is stable; the
    /// numbers inside them are read where present and skipped where not, so
    /// a payload this code has not seen still lists as "1 hang" rather than
    /// vanishing.
    nonisolated static func summarize(_ data: Data, receivedAt: Date, url: URL) -> HealthReport {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let hangs = root["hangDiagnostics"] as? [[String: Any]] ?? []
        let crashes = root["crashDiagnostics"] as? [[String: Any]] ?? []
        let launches = root["appLaunchDiagnostics"] as? [[String: Any]] ?? []

        var parts: [String] = []
        if !hangs.isEmpty {
            let longest = hangs.compactMap { seconds($0["hangDuration"]) }.max()
            parts.append("\(hangs.count) hang\(hangs.count == 1 ? "" : "s")"
                         + (longest.map { " (\(Int($0.rounded())) s)" } ?? ""))
        }
        if !crashes.isEmpty {
            let reason = crashes.lazy.compactMap { crash -> String? in
                (crash["terminationReason"] as? String)
                    ?? (crash["signal"] as? String)
                    ?? (crash["exceptionType"] as? String)
            }.first
            parts.append("\(crashes.count) crash\(crashes.count == 1 ? "" : "es")"
                         + (reason.map { ": \($0)" } ?? ""))
        }
        if !launches.isEmpty {
            parts.append("\(launches.count) slow launch\(launches.count == 1 ? "" : "es")")
        }
        return HealthReport(
            url: url, receivedAt: receivedAt,
            hangs: hangs.count, crashes: crashes.count, slowLaunches: launches.count,
            headline: parts.isEmpty ? "Diagnostics" : parts.joined(separator: ", "))
    }

    /// MetricKit writes durations as measurements — "6 sec", "1,200 ms" — and
    /// sometimes as bare numbers. Take what can be read.
    private nonisolated static func seconds(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let dict = value as? [String: Any], let number = dict["value"] as? Double {
            return (dict["unit"] as? String)?.hasPrefix("ms") == true ? number / 1000 : number
        }
        guard let text = value as? String else { return nil }
        let digits = text.replacingOccurrences(of: ",", with: "")
            .prefix { $0.isNumber || $0 == "." }
        guard let number = Double(digits) else { return nil }
        return text.contains("ms") ? number / 1000 : number
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    private static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Health", isDirectory: true)
    }
}

#if canImport(MetricKit) && os(iOS)
/// The NSObject MetricKit wants, kept apart so `Health` can stay a plain
/// observable class.
private final class MetricBridge: NSObject, MXMetricManagerSubscriber {
    private let deliver: @Sendable (Data) -> Void

    init(deliver: @escaping @Sendable (Data) -> Void) {
        self.deliver = deliver
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads { deliver(payload.jsonRepresentation()) }
    }

    // Metrics (battery, launch time histograms) are not kept. They say
    // nothing about a freeze, and they are the part of MetricKit that looks
    // like telemetry.
    func didReceive(_ payloads: [MXMetricPayload]) {}
}
#endif
