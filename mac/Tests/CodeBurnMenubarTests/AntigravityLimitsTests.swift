import AppKit
import SwiftUI
import XCTest
@testable import CodeBurnMenubar

/// `codeburn limits --provider antigravity`: one Claude-shaped report per
/// quota group. The Gemini group reuses the Claude fixture; the other group
/// has no activity.
enum AntigravityLimitsFixture {
    static func json(thirdPartyActive: Bool = false) throws -> Data {
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ClaudeLimitsFixture.json.utf8)) as? [String: Any])
        var idle = report
        if !thirdPartyActive {
            idle["sessions"] = [[String: Any]]()
            idle["weeks"] = [[String: Any]]()
            idle["current"] = ["session": NSNull(), "week": NSNull()]
        }
        let root: [String: Any] = [
            "generatedAt": "2026-10-14T12:00:00.000Z",
            "plan": "Google AI Pro",
            "readingsThrough": "2026-10-14T11:50:00.000Z",
            "groups": [
                ["id": "3p", "name": "Claude and GPT models", "models": ["Claude Sonnet 4.6"], "report": idle],
                ["id": "gemini", "name": "Gemini Models", "models": ["Gemini 3.1 Pro (High)"], "report": report],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: root)
    }

    static func report(thirdPartyActive: Bool = false) throws -> AntigravityLimitsReport {
        try AntigravityLimitsReport.decode(json(thirdPartyActive: thirdPartyActive))
    }
}

@MainActor
final class AntigravityLimitsTests: XCTestCase {
    private var logPath: String!

    override func setUp() {
        super.setUp()
        logPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("ag-limits-\(UUID().uuidString).jsonl")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: logPath)
        super.tearDown()
    }

    func testDecodesGroupsAndShowsOnlyTheUsedOnes() throws {
        let report = try AntigravityLimitsFixture.report()
        XCTAssertEqual(report.plan, "Google AI Pro")
        XCTAssertEqual(report.groups.map(\.shortName), ["Claude and GPT", "Gemini"])
        XCTAssertEqual(report.shownGroups.map(\.id), ["gemini"])
        XCTAssertEqual(report.defaultGroupID, "gemini")
        XCTAssertEqual(report.groups[1].report.current.session?.fiveHourPct, 61)
    }

    func testDefaultGroupIsTheOneWithARunningSession() throws {
        let both = try AntigravityLimitsFixture.report(thirdPartyActive: true)
        XCTAssertEqual(both.shownGroups.count, 2)
        // Both run a session in the fixture; ties keep the first maximum.
        XCTAssertNotNil(both.defaultGroupID)
    }

    func testNoActivityStillShowsTheFirstGroup() throws {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: AntigravityLimitsFixture.json()) as? [String: Any])
        var groups = try XCTUnwrap(root["groups"] as? [[String: Any]])
        groups.removeLast()
        root["groups"] = groups
        let report = try AntigravityLimitsReport.decode(JSONSerialization.data(withJSONObject: root))
        XCTAssertEqual(report.shownGroups.map(\.id), ["3p"])
    }

    private func usage(groups: [AntigravityUsage.Group]) -> AntigravityUsage {
        AntigravityUsage(details: [], plan: "Google AI Pro", fetchedAt: Date(), groups: groups, source: .remote)
    }

    func testLogsEveryGroupAsPercentUsed() async throws {
        let resets = ISO8601DateFormatter().date(from: "2026-11-28T02:02:39Z")
        let usage = usage(groups: [
            .init(id: "gemini", name: "Gemini Models", models: ["Gemini 3.1 Pro (High)"],
                  fiveHour: .init(remainingFraction: 0.99, resetsAt: resets),
                  weekly: .init(remainingFraction: 0.85, resetsAt: nil)),
            .init(id: "3p", name: "Claude and GPT models", models: [], fiveHour: nil, weekly: nil),
        ])
        let log = ClaudeLimitReadingLog(path: logPath)
        let at = Date(timeIntervalSince1970: 1_795_000_000)
        await AntigravityLimitReadingLog.record(usage, at: at, log: log)

        let text = try String(contentsOfFile: logPath, encoding: .utf8)
        let row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(row["ok"] as? Bool, true)
        XCTAssertEqual(row["plan"] as? String, "Google AI Pro")
        XCTAssertEqual(row["source"] as? String, "remote")
        let groups = try XCTUnwrap(row["groups"] as? [[String: Any]])
        XCTAssertEqual(groups.map { $0["id"] as? String }, ["gemini", "3p"])
        let five = try XCTUnwrap(groups[0]["five_hour"] as? [String: Any])
        XCTAssertEqual(five["pct"] as? Double, 1)
        XCTAssertEqual(five["resetsAt"] as? String, "2026-11-28T02:02:39.000Z")
        let week = try XCTUnwrap(groups[0]["seven_day"] as? [String: Any])
        XCTAssertEqual(week["pct"] as? Double, 15)
        XCTAssertTrue(week["resetsAt"] is NSNull)
        XCTAssertNil(groups[1]["five_hour"])
    }

    func testLegacyPayloadWithoutGroupsIsLoggedAsNoWindows() async throws {
        XCTAssertNil(AntigravityLimitReadingLog.successLine(usage(groups: []), at: Date()))
        await AntigravityLimitReadingLog.record(usage(groups: []), log: ClaudeLimitReadingLog(path: logPath))
        let text = try String(contentsOfFile: logPath, encoding: .utf8)
        XCTAssertTrue(text.contains(#""reason":"no_windows""#))
    }

    func testNoSignInIsNotAGapButSignedOutIs() {
        XCTAssertNil(AntigravityLimitReadingLog.failureReason(AntigravitySubscriptionService.FetchError.disconnected))
        XCTAssertEqual(AntigravityLimitReadingLog.failureReason(AntigravitySubscriptionService.FetchError.signedOut), .auth)
        XCTAssertEqual(AntigravityLimitReadingLog.failureReason(AntigravitySubscriptionService.FetchError.remote("503")), .network)
        XCTAssertEqual(AntigravityLimitReadingLog.failureReason(URLError(.timedOut)), .network)
    }

    func testActivityMonitorCountsOnlyItsOwnSuffixes() {
        let monitor = AntigravityActivity.monitor
        XCTAssertEqual(monitor.suffixes, [".db", ".db-wal", ".pb"])
        XCTAssertEqual(ClaudeActivityMonitor.shared.suffixes, [".jsonl"])
    }

    func testLiveReadingPreferenceDefaultsOn() {
        let (defaults, suite) = TestDefaults.make("codeburn.tests.antigravity-live-reading")
        defer { TestDefaults.forget(suite) }
        XCTAssertTrue(AntigravityLiveReadingPreference.isEnabled(defaults: defaults))
        defaults.set(false, forKey: AntigravityLiveReadingPreference.defaultsKey)
        XCTAssertFalse(AntigravityLiveReadingPreference.isEnabled(defaults: defaults))
    }

    /// The section at the popover's content width, with the group switch.
    /// `CODEBURN_LAYOUT_PROOF_DIR` writes the render as a PNG for review.
    func testSectionRendersAtPopoverWidth() throws {
        let store = AppStore()
        store.suppressRefreshesForTesting()
        let width: CGFloat = 360 - 28
        for (name, report) in [("one-group", try AntigravityLimitsFixture.report()), ("two-groups", try AntigravityLimitsFixture.report(thirdPartyActive: true))] {
            let renderer = ImageRenderer(content: AntigravitySessionsPlanSection(report: report)
                .environment(store)
                .environment(\.colorScheme, .dark)
                .frame(width: width)
                .padding(14)
                .background(Color(white: 0.12)))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage)
            XCTAssertEqual(CGFloat(image.width) / 2, width + 28)
            if let dir = ProcessInfo.processInfo.environment["CODEBURN_LAYOUT_PROOF_DIR"],
               let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("antigravity-sessions-\(name).png"))
            }
        }
    }
}
