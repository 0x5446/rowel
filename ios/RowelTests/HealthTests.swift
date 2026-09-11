/// The one place a freeze leaves a trace the app can show.
///
/// These do not exercise MetricKit itself — the simulator never delivers a
/// payload, and a device delivers on its own schedule. What they pin is the
/// part that is ours: that a payload written to disk comes back as a report a
/// person can read, that the shape MetricKit uses today is summarised
/// correctly, and that a shape it has not used yet still lists rather than
/// disappearing.

import XCTest
@testable import Rowel

final class HealthTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("health-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private static let payload = """
    {
      "hangDiagnostics": [
        { "diagnosticMetaData": { "appVersion": "1.0", "osVersion": "iOS 26.6.1" },
          "hangDuration": "6 sec",
          "callStackTree": { "callStacks": [] } }
      ],
      "crashDiagnostics": [
        { "diagnosticMetaData": { "appVersion": "1.0" },
          "terminationReason": "Namespace SPRINGBOARD, Code 0x8badf00d",
          "signal": "SIGKILL",
          "callStackTree": { "callStacks": [] } }
      ]
    }
    """.data(using: .utf8)!

    @MainActor
    func testAPayloadBecomesAReadableReport() throws {
        let health = Health(directory: directory)
        XCTAssertTrue(health.reports.isEmpty)

        health.record(HealthTests.payload)

        let report = try XCTUnwrap(health.reports.first)
        XCTAssertEqual(report.hangs, 1)
        XCTAssertEqual(report.crashes, 1)
        XCTAssertEqual(report.headline, "1 hang (6 s), 1 crash: Namespace SPRINGBOARD, Code 0x8badf00d")
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.url.path), "the file is what gets shared")
    }

    @MainActor
    func testReportsSurviveARelaunch() throws {
        Health(directory: directory).record(HealthTests.payload)
        // A second instance is what the next launch constructs.
        let later = Health(directory: directory)
        XCTAssertEqual(later.reports.count, 1)
    }

    func testAnUnfamiliarShapeStillLists() throws {
        // A future iOS that renames every inner key. The arrays are still
        // arrays, so the counts hold and nothing is silently dropped.
        let odd = """
        { "hangDiagnostics": [ { "somethingNew": true } ], "appLaunchDiagnostics": [ {}, {} ] }
        """.data(using: .utf8)!
        let report = Health.summarize(odd, receivedAt: Date(), url: directory)
        XCTAssertEqual(report.hangs, 1)
        XCTAssertEqual(report.slowLaunches, 2)
        XCTAssertEqual(report.headline, "1 hang, 2 slow launches")
    }

    func testDurationsInEveryShapeMetricKitHasUsed() {
        func headline(_ duration: String) -> String {
            let data = #"{ "hangDiagnostics": [ { "hangDuration": \#(duration) } ] }"#.data(using: .utf8)!
            return Health.summarize(data, receivedAt: Date(), url: directory).headline
        }
        XCTAssertEqual(headline(#""6 sec""#), "1 hang (6 s)")
        XCTAssertEqual(headline(#""1,500 ms""#), "1 hang (2 s)")
        XCTAssertEqual(headline("4.2"), "1 hang (4 s)")
        XCTAssertEqual(headline(#"{ "value": 3000, "unit": "ms" }"#), "1 hang (3 s)")
    }
}
