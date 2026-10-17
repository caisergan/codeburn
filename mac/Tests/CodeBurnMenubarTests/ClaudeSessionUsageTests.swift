import Foundation
import XCTest
@testable import CodeBurnMenubar

/// Claude session and week usage: the reading schedule, the reading log, the
/// snapshot store fixes, and the presentation of `codeburn limits`.
/// See docs/design/claude-session-usage.md.
final class ClaudeLiveReadingScheduleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func due(
        enabled: Bool = true,
        connected: Bool = true,
        writtenAgo: TimeInterval? = 30,
        attemptedAgo: TimeInterval? = nil,
        backoffIn: TimeInterval? = nil,
        lowPower: Bool = false
    ) -> Bool {
        QuotaRefreshDecision.claudeLiveReadingDue(
            enabled: enabled,
            connected: connected,
            lastClaudeWriteAt: writtenAgo.map { now.addingTimeInterval(-$0) },
            lastAttemptAt: attemptedAgo.map { now.addingTimeInterval(-$0) },
            backoffUntil: backoffIn.map { now.addingTimeInterval($0) },
            lowPowerMode: lowPower,
            now: now
        )
    }

    func testReadsEveryTwoMinutesWhileClaudeIsWorking() {
        XCTAssertTrue(due(attemptedAgo: nil))
        XCTAssertTrue(due(attemptedAgo: 120))
        // The 30s loop ticks with leeway; a tick a few seconds early still counts.
        XCTAssertTrue(due(attemptedAgo: 117))
        XCTAssertFalse(due(attemptedAgo: 90))
    }

    func testKeepsReadingThroughTheTenMinuteTail() {
        XCTAssertTrue(due(writtenAgo: 9 * 60 + 59, attemptedAgo: 150))
        XCTAssertTrue(due(writtenAgo: 10 * 60, attemptedAgo: 150))
        XCTAssertFalse(due(writtenAgo: 10 * 60 + 1, attemptedAgo: 150))
    }

    func testReadsEveryFiveMinutesInLowPowerMode() {
        XCTAssertFalse(due(attemptedAgo: 150, lowPower: true))
        XCTAssertTrue(due(attemptedAgo: 300, lowPower: true))
    }

    func testNothingWhileIdleOrOffOrDisconnected() {
        XCTAssertFalse(due(writtenAgo: nil))
        XCTAssertFalse(due(enabled: false))
        XCTAssertFalse(due(connected: false))
    }

    func testFailureBackoffWins() {
        XCTAssertFalse(due(attemptedAgo: 600, backoffIn: 30))
        XCTAssertTrue(due(attemptedAgo: 600, backoffIn: -1))
    }

    func testPreferenceDefaultsOn() {
        let (defaults, name) = TestDefaults.make("ClaudeLiveReadingScheduleTests.preference")
        defer { TestDefaults.forget(name) }
        XCTAssertTrue(ClaudeLiveReadingPreference.isEnabled(defaults: defaults))
        defaults.set(false, forKey: ClaudeLiveReadingPreference.defaultsKey)
        XCTAssertFalse(ClaudeLiveReadingPreference.isEnabled(defaults: defaults))
    }

    func testRateLimitBlockIsCappedAtThirtyMinutes() {
        let blocked = ClaudeSubscriptionService.rateLimitBlockUntil(existingUntil: nil, now: now, retryAfterSeconds: 4 * 3600)
        XCTAssertEqual(blocked, now.addingTimeInterval(30 * 60))
        let carried = ClaudeSubscriptionService.rateLimitBlockUntil(
            existingUntil: now.addingTimeInterval(6 * 3600), now: now, retryAfterSeconds: 60
        )
        XCTAssertEqual(carried, now.addingTimeInterval(30 * 60))
    }

    func testLimitsIsServedByTheResidentChild() {
        XCTAssertTrue(ServeConnection.isEligible(DataClient.claudeLimitsSubcommand))
    }
}

final class ClaudeLimitReadingLogTests: XCTestCase {
    private var directory: URL!
    private var suite: String!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("cb-reading-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "ClaudeLimitReadingLogTests.\(name.filter { $0.isLetter || $0.isNumber })"
        TestDefaults.forget(suite)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        TestDefaults.forget(suite)
    }

    private var logPath: String { directory.appendingPathComponent(ClaudeLimitReadingLog.filename).path }

    private func lines() throws -> [[String: Any]] {
        let text = try String(contentsOfFile: logPath, encoding: .utf8)
        XCTAssertTrue(text.hasSuffix("\n"))
        return try text.split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    private func usage(fiveHour: Double? = 58, sevenDay: Double? = 8) -> SubscriptionUsage {
        SubscriptionUsage(
            tier: .max5x,
            rawTier: "default_claude_max_5x",
            fiveHourPercent: fiveHour,
            fiveHourResetsAt: ISO8601DateFormatter().date(from: "2026-10-14T13:00:00Z"),
            sevenDayPercent: sevenDay,
            sevenDayResetsAt: ISO8601DateFormatter().date(from: "2026-10-21T08:00:00Z"),
            sevenDayOpusPercent: nil,
            sevenDayOpusResetsAt: nil,
            sevenDaySonnetPercent: nil,
            sevenDaySonnetResetsAt: nil,
            scopedWeekly: [.init(label: "Fable", percent: 0, resetsAt: nil)],
            fetchedAt: Date()
        )
    }

    func testRecordsEveryCheckIncludingFailuresWithReasons() async throws {
        let log = ClaudeLimitReadingLog(path: logPath, defaultsSuite: suite)
        let at = Date(timeIntervalSince1970: 1_791_000_000)
        await log.recordSuccess(usage(), at: at)
        await log.recordFailure(ClaudeSubscriptionService.FetchError.rateLimited(retryAt: at.addingTimeInterval(300)), at: at)
        await log.recordFailure(ClaudeSubscriptionService.FetchError.usageDecodeFailed, at: at)
        await log.recordFailure(ClaudeSubscriptionService.FetchError.usageHTTPError(401, nil), at: at)
        await log.recordFailure(URLError(.notConnectedToInternet), at: at)
        await log.recordSuccess(usage(fiveHour: nil, sevenDay: nil), at: at)

        let rows = try lines()
        XCTAssertEqual(rows.count, 6)
        XCTAssertEqual(rows[0]["ok"] as? Bool, true)
        XCTAssertEqual(rows[0]["plan"] as? String, "Max 5x")
        XCTAssertEqual((rows[0]["five_hour"] as? [String: Any])?["pct"] as? Double, 58)
        XCTAssertEqual((rows[0]["seven_day"] as? [String: Any])?["resetsAt"] as? String, "2026-10-21T08:00:00.000Z")
        XCTAssertEqual(((rows[0]["scoped"] as? [[String: Any]])?.first)?["label"] as? String, "Weekly · Fable")
        XCTAssertEqual(rows[1]["reason"] as? String, "rate_limited")
        XCTAssertEqual(rows[1]["retryAfter"] as? Int, 300)
        XCTAssertEqual(rows[2]["reason"] as? String, "decode")
        XCTAssertEqual(rows[3]["reason"] as? String, "auth")
        XCTAssertEqual(rows[4]["reason"] as? String, "network")
        XCTAssertEqual(rows[5]["reason"] as? String, "no_windows")

        let attributes = try FileManager.default.attributesOfItem(atPath: logPath)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testRefusesToAppendThroughASymlink() async throws {
        let target = directory.appendingPathComponent("elsewhere.txt")
        try "keep".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: logPath, withDestinationPath: target.path)
        let log = ClaudeLimitReadingLog(path: logPath, defaultsSuite: suite)
        await log.recordFailure(.network, retryAfter: nil)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep")
    }

    func testPrunesLinesOlderThanThirtyFiveDaysOnceADay() async throws {
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        let old = now.addingTimeInterval(-36 * 86400)
        let recent = now.addingTimeInterval(-30 * 86400)
        let log = ClaudeLimitReadingLog(path: logPath, defaultsSuite: suite)
        await log.recordFailure(.network, retryAfter: nil, at: old)
        await log.recordFailure(.network, retryAfter: nil, at: recent)
        await log.pruneIfDue(now: now)
        XCTAssertEqual(try lines().count, 1)

        // Within the day, a second prune does nothing.
        await log.recordFailure(.network, retryAfter: nil, at: old)
        await log.pruneIfDue(now: now.addingTimeInterval(3600))
        XCTAssertEqual(try lines().count, 2)
        await log.pruneIfDue(now: now.addingTimeInterval(25 * 3600))
        XCTAssertEqual(try lines().count, 1)
    }

    func testImportsSnapshotHistoryOnceAsImportedReadings() async throws {
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        let snapshots = directory.appendingPathComponent("subscription-snapshots.json")
        let captured = now.addingTimeInterval(-3600)
        let rows = [
            SubscriptionSnapshot(windowKey: "five_hour", percent: 21, resetsAt: now.addingTimeInterval(3600), capturedAt: captured, effectiveTokens: nil),
            SubscriptionSnapshot(windowKey: "seven_day", percent: 3, resetsAt: now.addingTimeInterval(5 * 86400), capturedAt: captured, effectiveTokens: 1),
            SubscriptionSnapshot(windowKey: "seven_day_opus", percent: 1, resetsAt: now.addingTimeInterval(5 * 86400), capturedAt: captured, effectiveTokens: nil),
            SubscriptionSnapshot(windowKey: "five_hour", percent: 90, resetsAt: now, capturedAt: now.addingTimeInterval(-40 * 86400), effectiveTokens: nil),
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(rows).write(to: snapshots)

        let log = ClaudeLimitReadingLog(path: logPath, defaultsSuite: suite)
        await log.importSnapshotsIfNeeded(from: snapshots.path, now: now)
        await log.importSnapshotsIfNeeded(from: snapshots.path, now: now)
        let lines = try lines()
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0]["imported"] as? Bool, true)
        XCTAssertEqual((lines[0]["five_hour"] as? [String: Any])?["pct"] as? Double, 21)
        XCTAssertEqual((lines[0]["seven_day"] as? [String: Any])?["pct"] as? Double, 3)
    }

    func testUnreadableSnapshotsAreRetriedNextLaunch() async throws {
        let snapshots = directory.appendingPathComponent("subscription-snapshots.json")
        try Data("not json".utf8).write(to: snapshots)
        let log = ClaudeLimitReadingLog(path: logPath, defaultsSuite: suite)
        await log.importSnapshotsIfNeeded(from: snapshots.path)
        XCTAssertFalse(TestDefaults.open(suite).bool(forKey: ClaudeLimitReadingLog.importedDefaultsKey))
    }
}

final class SubscriptionSnapshotStoreFixTests: XCTestCase {
    private var path: String!

    override func setUp() {
        path = FileManager.default.temporaryDirectory.appendingPathComponent("snapshots-\(UUID().uuidString).json").path
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: path)
    }

    func testResetJitterKeepsOneRowPerWindow() async throws {
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        let reset = Date(timeIntervalSince1970: 1_791_003_600)
        await SubscriptionSnapshotStore.record(
            SubscriptionSnapshot(windowKey: "five_hour", percent: 10, resetsAt: reset.addingTimeInterval(-0.4), capturedAt: now, effectiveTokens: nil),
            path: path, now: now
        )
        await SubscriptionSnapshotStore.record(
            SubscriptionSnapshot(windowKey: "five_hour", percent: 30, resetsAt: reset, capturedAt: now.addingTimeInterval(60), effectiveTokens: nil),
            path: path, now: now
        )
        await SubscriptionSnapshotStore.record(
            SubscriptionSnapshot(windowKey: "five_hour", percent: 20, resetsAt: reset.addingTimeInterval(0.7), capturedAt: now.addingTimeInterval(120), effectiveTokens: nil),
            path: path, now: now
        )
        let rows = try XCTUnwrap(SubscriptionSnapshotStore.loadAllForUpdate(path: path))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.percent, 30)
    }

    func testAFailedLoadNeverOverwritesTheFile() async throws {
        let garbage = Data("[{\"windowKey\": truncated".utf8)
        try garbage.write(to: URL(fileURLWithPath: path))
        XCTAssertNil(SubscriptionSnapshotStore.loadAllForUpdate(path: path))
        await SubscriptionSnapshotStore.record(
            SubscriptionSnapshot(windowKey: "seven_day", percent: 5, resetsAt: Date(), capturedAt: Date(), effectiveTokens: nil),
            path: path
        )
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), garbage)
    }

    func testAMissingFileIsEmptyNotUnreadable() {
        XCTAssertEqual(SubscriptionSnapshotStore.loadAllForUpdate(path: path)?.count, 0)
    }
}

/// Output of `computeClaudeLimits` for a small fixture: a running session,
/// a measured one, a week that ran out at 03:47, and a rate-limited gap.
enum ClaudeLimitsFixture {
    static let json = #"""
{"generatedAt":"2026-10-14T12:00:00.000Z","plan":"Max 5x","readingsThrough":"2026-10-14T11:50:00.000Z","current":{"session":{"id":"2026-10-14T16:00:00.000Z","start":"2026-10-14T11:00:00.000Z","end":"2026-10-14T16:00:00.000Z","startInferred":false,"running":true,"spentUSD":116,"tokens":{"input":20,"output":40,"cacheRead":2000000,"cacheWrite":2000},"fiveHourPct":61,"fiveHourQuality":"measured","weekPct":8,"weekQuality":"estimated","fullSessionUSD":190.1639344262295,"fullSessionQuality":"estimated","outsideThisMac":false,"unpricedModels":[],"chats":[{"sessionId":"a","title":"Refactor the auth flow","spentUSD":80,"project":"api-server","path":"/Users/me/api-server","firstAt":"2026-10-14T11:05:00.000Z","lastAt":"2026-10-14T11:50:00.000Z","promptCount":5,"prompts":[{"at":"2026-10-14T11:04:00.000Z","text":"The login form keeps the old session cookie after a password change. Find where we issue it and make the refresh path rotate it, then add a test for the expired-token case."},{"at":"2026-10-14T11:20:00.000Z","text":"yes, go with your recommendation"},{"at":"2026-10-14T11:31:00.000Z","text":"run the tests first"},{"at":"2026-10-14T11:44:00.000Z","text":"now open the pr"}]},{"sessionId":"d","title":"Fix the onboarding layout","spentUSD":36,"project":"web","firstAt":"2026-10-14T11:40:00.000Z","lastAt":"2026-10-14T11:40:00.000Z","promptCount":1,"prompts":[{"at":"2026-10-14T11:39:00.000Z","text":"the onboarding header overlaps the steps on small windows"}]}],"models":[{"model":"Opus 5.5","spentUSD":104,"tokens":1800000},{"model":"Haiku 5.5","spentUSD":12,"tokens":202060}],"hours":[{"start":"2026-10-14T11:00:00.000Z","end":"2026-10-14T12:00:00.000Z","spentUSD":116,"tokens":2002060,"fiveHourPct":61}]},"week":{"start":"2026-10-14T08:00:00.000Z","end":"2026-10-21T08:00:00.000Z","endReason":"running","startInferred":false,"running":true,"spentUSD":116,"tokens":{"input":20,"output":40,"cacheRead":2000000,"cacheWrite":2000},"usedPct":8,"usedQuality":"measured","fullWeekUSD":1450,"fullWeekQuality":"estimated","unpricedModels":[],"models":[{"model":"Opus 5.5","spentUSD":104,"tokens":1800000},{"model":"Haiku 5.5","spentUSD":12,"tokens":202060}],"days":[{"start":"2026-10-14T08:00:00.000Z","end":"2026-10-15T08:00:00.000Z","spentUSD":116,"tokens":2002060,"usedPct":8}],"sessions":[{"id":"2026-10-14T16:00:00.000Z","start":"2026-10-14T11:00:00.000Z","end":"2026-10-14T16:00:00.000Z","running":true,"spentUSD":116,"weekPct":8,"weekQuality":"estimated"}],"previousAtSamePoint":{"at":"2026-10-07T12:00:00.000Z","spentUSD":150,"usedPct":11,"usedQuality":"measured"}}},"rate":{"weekPerSessionPoint":null,"basis":1,"restartedAt":null},"sessionsLeft":null,"runsOutFirstAtSessionPct":null,"fullWeekAverage":{"usd":198.67,"basis":1},"sessions":[{"id":"2026-10-14T16:00:00.000Z","start":"2026-10-14T11:00:00.000Z","end":"2026-10-14T16:00:00.000Z","startInferred":false,"running":true,"spentUSD":116,"tokens":{"input":20,"output":40,"cacheRead":2000000,"cacheWrite":2000},"fiveHourPct":61,"fiveHourQuality":"measured","weekPct":8,"weekQuality":"estimated","fullSessionUSD":190.1639344262295,"fullSessionQuality":"estimated","outsideThisMac":false,"unpricedModels":[],"chats":[{"sessionId":"a","title":"Refactor the auth flow","spentUSD":80,"project":"api-server","path":"/Users/me/api-server","firstAt":"2026-10-14T11:05:00.000Z","lastAt":"2026-10-14T11:50:00.000Z","promptCount":5,"prompts":[{"at":"2026-10-14T11:04:00.000Z","text":"The login form keeps the old session cookie after a password change. Find where we issue it and make the refresh path rotate it, then add a test for the expired-token case."},{"at":"2026-10-14T11:20:00.000Z","text":"yes, go with your recommendation"},{"at":"2026-10-14T11:31:00.000Z","text":"run the tests first"},{"at":"2026-10-14T11:44:00.000Z","text":"now open the pr"}]},{"sessionId":"d","title":"Fix the onboarding layout","spentUSD":36,"project":"web","firstAt":"2026-10-14T11:40:00.000Z","lastAt":"2026-10-14T11:40:00.000Z","promptCount":1,"prompts":[{"at":"2026-10-14T11:39:00.000Z","text":"the onboarding header overlaps the steps on small windows"}]}],"models":[{"model":"Opus 5.5","spentUSD":104,"tokens":1800000},{"model":"Haiku 5.5","spentUSD":12,"tokens":202060}],"hours":[{"start":"2026-10-14T11:00:00.000Z","end":"2026-10-14T12:00:00.000Z","spentUSD":116,"tokens":2002060,"fiveHourPct":61}]},{"id":"2026-10-14T07:30:00.000Z","start":"2026-10-14T02:30:00.000Z","end":"2026-10-14T07:30:00.000Z","startInferred":true,"running":false,"spentUSD":13.8,"tokens":{"input":10,"output":20,"cacheRead":1000000,"cacheWrite":1000},"fiveHourPct":null,"fiveHourQuality":"unknown","weekPct":6.9,"weekQuality":"estimated","fullSessionQuality":"unknown","ranOut":{"limit":"seven_day","at":"2026-10-14T03:47:00.000Z","spentUSD":13.8},"outsideThisMac":false,"unpricedModels":[],"chats":[{"sessionId":"c","title":"api-server · “c”","spentUSD":13.8}]},{"id":"2026-10-13T22:20:00.000Z","start":"2026-10-13T17:20:00.000Z","end":"2026-10-13T22:20:00.000Z","startInferred":false,"running":false,"spentUSD":184.87,"tokens":{"input":20,"output":40,"cacheRead":2000000,"cacheWrite":2000},"fiveHourPct":99,"fiveHourQuality":"measured","weekPct":12,"weekQuality":"measured","weekFrom":81,"weekTo":93,"fullSessionUSD":186.73737373737373,"fullSessionQuality":"estimated","outsideThisMac":false,"unpricedModels":[],"chats":[{"sessionId":"a","title":"api-server · “a”","spentUSD":100},{"sessionId":"b","title":"api-server · “b”","spentUSD":84.87}]}],"weeks":[{"start":"2026-10-14T08:00:00.000Z","end":"2026-10-21T08:00:00.000Z","endReason":"running","startInferred":false,"running":true,"spentUSD":116,"tokens":{"input":20,"output":40,"cacheRead":2000000,"cacheWrite":2000},"usedPct":8,"usedQuality":"measured","fullWeekUSD":1450,"fullWeekQuality":"estimated","unpricedModels":[],"models":[{"model":"Opus 5.5","spentUSD":104,"tokens":1800000},{"model":"Haiku 5.5","spentUSD":12,"tokens":202060}],"days":[{"start":"2026-10-14T08:00:00.000Z","end":"2026-10-15T08:00:00.000Z","spentUSD":116,"tokens":2002060,"usedPct":8}],"sessions":[{"id":"2026-10-14T16:00:00.000Z","start":"2026-10-14T11:00:00.000Z","end":"2026-10-14T16:00:00.000Z","running":true,"spentUSD":116,"weekPct":8,"weekQuality":"estimated"}],"previousAtSamePoint":{"at":"2026-10-07T12:00:00.000Z","spentUSD":150,"usedPct":11,"usedQuality":"measured"}},{"start":"2026-10-07T08:00:00.000Z","end":"2026-10-14T08:00:00.000Z","endReason":"reset","startInferred":false,"running":false,"spentUSD":198.67000000000002,"tokens":{"input":30,"output":60,"cacheRead":3000000,"cacheWrite":3000},"usedPct":100,"usedQuality":"exact","fullWeekUSD":198.67000000000002,"fullWeekQuality":"exact","ranOutAt":"2026-10-14T03:47:00.000Z","unpricedModels":[],"days":[{"start":"2026-10-07T08:00:00.000Z","end":"2026-10-08T08:00:00.000Z","spentUSD":40,"tokens":600000,"usedPct":30},{"start":"2026-10-08T08:00:00.000Z","end":"2026-10-09T08:00:00.000Z","spentUSD":0,"tokens":0,"usedPct":null},{"start":"2026-10-13T08:00:00.000Z","end":"2026-10-14T08:00:00.000Z","spentUSD":158.67,"tokens":2400000,"usedPct":100}],"sessions":[{"id":"2026-10-13T22:20:00.000Z","start":"2026-10-13T17:20:00.000Z","end":"2026-10-13T22:20:00.000Z","running":false,"spentUSD":184.87,"weekPct":12,"weekQuality":"measured"},{"id":"2026-10-14T07:30:00.000Z","start":"2026-10-14T02:30:00.000Z","end":"2026-10-14T07:30:00.000Z","running":false,"spentUSD":13.8,"weekPct":6.9,"weekQuality":"estimated"}]},{"start":"2026-09-30T08:00:00.000Z","end":"2026-10-07T08:00:00.000Z","endReason":"inferred","startInferred":true,"running":false,"spentUSD":0,"tokens":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0},"usedPct":null,"usedQuality":"unknown","fullWeekQuality":"unknown","unpricedModels":[]},{"start":"2026-09-23T08:00:00.000Z","end":"2026-09-30T08:00:00.000Z","endReason":"inferred","startInferred":true,"running":false,"spentUSD":0,"tokens":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0},"usedPct":null,"usedQuality":"unknown","fullWeekQuality":"unknown","unpricedModels":[]}],"gaps":[{"from":"2026-10-14T02:00:00.000Z","to":"2026-10-14T02:00:00.000Z","reason":"rate_limited"}]}
"""#

    static func report() throws -> ClaudeLimitsReport {
        try ClaudeLimitsReport.decode(Data(json.utf8))
    }

    /// The fixture with its oldest session (Tue 17:20–22:20 UTC) spending
    /// `spentUSD` after a midnight at `at`, without its newest `dropping`
    /// sessions.
    static func report(afterMidnight at: String, spentUSD: Double, dropping: Int = 0) throws -> ClaudeLimitsReport {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        var sessions = try XCTUnwrap(root["sessions"] as? [[String: Any]])
        sessions[sessions.count - 1]["afterMidnight"] = ["at": at, "spentUSD": spentUSD]
        root["sessions"] = Array(sessions.dropFirst(dropping))
        return try ClaudeLimitsReport.decode(JSONSerialization.data(withJSONObject: root))
    }
}

@MainActor
final class ClaudeLimitsPresentationTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!

    private func report() throws -> ClaudeLimitsReport {
        try ClaudeLimitsReport.decode(Data(ClaudeLimitsFixture.json.utf8))
    }

    func testDecodesTheCLIOutput() throws {
        let report = try report()
        XCTAssertEqual(report.plan, "Max 5x")
        let session = try XCTUnwrap(report.current.session)
        XCTAssertTrue(session.running)
        XCTAssertEqual(session.fiveHourPct, 61)
        XCTAssertEqual(session.fiveHourQuality, .measured)
        XCTAssertEqual(session.weekQuality, .estimated)
        XCTAssertEqual(report.sessions.count, 3)
        let measured = try XCTUnwrap(report.sessions.last)
        XCTAssertEqual(measured.weekPct, 12)
        XCTAssertEqual(measured.weekFrom, 81)
        XCTAssertEqual(measured.weekTo, 93)
        XCTAssertEqual(report.weeks.first?.endReason, .running)
        XCTAssertEqual(report.weeks[1].ranOutAt, ClaudeLimitsReport.parseDate("2026-10-14T03:47:00.000Z"))
        XCTAssertNil(report.rate.weekPerSessionPoint)
        XCTAssertEqual(report.gaps.first?.reason, "rate_limited")
        XCTAssertEqual(session.hours?.first?.pct, 61)
        XCTAssertEqual(session.models?.map(\.model), ["Opus 5.5", "Haiku 5.5"])
        XCTAssertEqual(report.weeks[0].days?.first?.pct, 8)
        XCTAssertEqual(report.weeks[0].previousAtSamePoint?.usedPct, 11)
        XCTAssertNil(report.weeks[1].days?[1].pct)
        XCTAssertEqual(report.weeks[1].sessions?.map(\.weekPct), [12, 6.9])
        XCTAssertEqual(report.fullWeekAverage?.basis, 1)
        let chat = try XCTUnwrap(session.chats.first)
        XCTAssertEqual(chat.project, "api-server")
        XCTAssertEqual(chat.promptCount, 5)
        XCTAssertEqual(chat.prompts?.count, 4)
        XCTAssertNil(report.sessions[1].chats.first?.prompts)
    }

    /// A CLI from before the tabbed detail sends none of the breakdowns.
    func testDecodesAnOlderCLIWithoutBreakdowns() throws {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ClaudeLimitsFixture.json.utf8)) as? [String: Any])
        func strip(_ object: Any) -> Any {
            if let array = object as? [Any] { return array.map(strip) }
            guard var dict = object as? [String: Any] else { return object }
            // A week's `sessions` holds `running` blocks; the report's own
            // `sessions` holds full sessions with chats and stays.
            if dict["usedPct"] != nil || dict["fiveHourPct"] != nil && dict["chats"] != nil {
                for key in ["models", "hours", "days", "previousAtSamePoint"] { dict[key] = nil }
                if dict["usedPct"] != nil { dict["sessions"] = nil }
            }
            return dict.mapValues(strip)
        }
        root = strip(root) as! [String: Any]
        root["fullWeekAverage"] = nil
        let data = try JSONSerialization.data(withJSONObject: root)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\"hours\""))
        let report = try ClaudeLimitsReport.decode(data)
        XCTAssertNil(report.current.session?.hours)
        XCTAssertNil(report.weeks[0].sessions)
        XCTAssertNil(report.weeks[0].previousAtSamePoint)
        XCTAssertNil(report.fullWeekAverage)
        XCTAssertEqual(report.sessions.count, 3)
    }

    func testDisplayRules() {
        XCTAssertEqual(ClaudeSessionFormat.percent(61, .measured), "61%")
        XCTAssertEqual(ClaudeSessionFormat.percent(57.4, .lowerBound), "≥57%")
        XCTAssertEqual(ClaudeSessionFormat.percent(7.6, .estimated, signed: true), "≈+8%")
        XCTAssertEqual(ClaudeSessionFormat.percent(100, .exact), "100%")
        XCTAssertEqual(ClaudeSessionFormat.percent(nil, .unknown), "–")
        XCTAssertEqual(ClaudeSessionFormat.percent(12, .unknown), "–")
        XCTAssertEqual(ClaudeSessionFormat.money(1491.76, symbol: "$", rate: 1), "$1,492")
        XCTAssertEqual(ClaudeSessionFormat.money(184.871, cents: true, symbol: "$", rate: 1), "$184.87")
        XCTAssertEqual(ClaudeSessionFormat.money(116, unpriced: true, symbol: "€", rate: 0.5), "≥ €58")
        XCTAssertEqual(ClaudeSessionFormat.estimatedMoney(190, .estimated, symbol: "$", rate: 1), "≈ $190")
        XCTAssertEqual(ClaudeSessionFormat.estimatedMoney(101.75, .exact, symbol: "$", rate: 1), "$102")
    }

    func testSummaryLineSaysTheWeekRanOut() throws {
        var report = try report()
        // The fixture's current week has not run out; the line falls back to
        // "not enough sessions" until five qualify.
        XCTAssertEqual(ClaudeSessionFormat.summaryLine(report, timeZone: utc), "Not enough sessions yet to measure")
        let json = ClaudeLimitsFixture.json.replacingOccurrences(of: "\"usedQuality\":\"measured\",\"fullWeekUSD\"", with: "\"usedQuality\":\"measured\",\"ranOutAt\":\"2026-10-14T11:30:00.000Z\",\"fullWeekUSD\"")
        report = try ClaudeLimitsReport.decode(Data(json.utf8))
        XCTAssertNotNil(report.current.week?.ranOutAt)
        XCTAssertTrue(ClaudeSessionFormat.summaryLine(report, timeZone: utc).hasPrefix("Week ran out at 11:30 · resets "))
    }

    func testMenubarRowHidesWithNoSession() throws {
        let report = try report()
        XCTAssertEqual(ClaudeSessionFormat.menubarRow(report, symbol: "$", rate: 1), "5h 61% · $116 · wk ≈+8%")
        XCTAssertNil(ClaudeSessionFormat.menubarRow(nil, symbol: "$", rate: 1))
        let settings = MenubarRowSettings(isSecondRowEnabled: true, secondRowMetric: .claudeSession)
        XCTAssertEqual(
            MenubarRowFormatter.secondRow(settings: settings, snapshot: MenubarRowSnapshot(claudeLimits: report)),
            "5h 61% · $116 · wk ≈+8%"
        )
        XCTAssertNil(MenubarRowFormatter.secondRow(settings: settings, snapshot: MenubarRowSnapshot()))
    }

    func testSecondRowFitsTheBudgetWithWideMarks() throws {
        let json = ClaudeLimitsFixture.json
            .replacingOccurrences(of: "\"fiveHourPct\":61,\"fiveHourQuality\":\"measured\"", with: "\"fiveHourPct\":57,\"fiveHourQuality\":\"lowerBound\"")
        let report = try ClaudeLimitsReport.decode(Data(json.utf8))
        let row = try XCTUnwrap(ClaudeSessionFormat.menubarRow(report, symbol: "$", rate: 1))
        XCTAssertLessThanOrEqual(MenubarRowFormatter.displayCells(row), MenubarRowFormatter.secondRowCharacterBudget)
    }

    func testSessionRangeUsesTenMinuteMarksAndMarksInferredStarts() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let start = ClaudeLimitsReport.parseDate("2026-10-13T19:20:00Z")!
        let end = ClaudeLimitsReport.parseDate("2026-10-14T00:20:00Z")!
        let now = ClaudeLimitsReport.parseDate("2026-10-14T12:00:00Z")!
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(ClaudeSessionFormat.sessionRange(start: start, end: end, inferred: false, now: now, calendar: calendar, locale: locale), "Tue 19:20–00:20")
        XCTAssertEqual(ClaudeSessionFormat.sessionRange(start: start, end: end, inferred: true, now: now, calendar: calendar, locale: locale), "≈ Tue 19:20–00:20")
    }

    // MARK: Days

    private func calendar(_ zone: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        return c
    }

    /// In Istanbul the oldest session runs Tue 20:20–Wed 01:20: what it spent
    /// after 21:00Z goes under Wednesday, next to Wednesday's own rows.
    func testDaysCarryASessionsSpendPastMidnightIntoTheNextDay() throws {
        let report = try ClaudeLimitsFixture.report(afterMidnight: "2026-10-13T21:00:00.000Z", spentUSD: 120)
        let days = ClaudeSessionDay.days(report.sessions, calendar: calendar("Europe/Istanbul"))
        XCTAssertEqual(days.map { $0.sessions.map(\.id) }, [
            ["2026-10-14T16:00:00.000Z", "2026-10-14T07:30:00.000Z"],
            ["2026-10-13T22:20:00.000Z"],
        ])
        XCTAssertEqual(days[0].spentUSD, 129.8, accuracy: 0.001)
        let carry = try XCTUnwrap(days[0].carryOver)
        XCTAssertEqual(carry.session.id, "2026-10-13T22:20:00.000Z")
        XCTAssertEqual(carry.spentUSD, 120)
        XCTAssertEqual(carry.share, 120 / 184.87, accuracy: 0.0001)
        XCTAssertNil(days[1].carryOver)
    }

    /// Working past midnight with no session started since: today still gets
    /// its group, so its small hours are not missing from the list.
    func testADayWithNoSessionOfItsOwnStillGetsItsCarryOver() throws {
        let report = try ClaudeLimitsFixture.report(afterMidnight: "2026-10-13T21:00:00.000Z", spentUSD: 120, dropping: 2)
        let days = ClaudeSessionDay.days(report.sessions, calendar: calendar("Europe/Istanbul"))
        XCTAssertEqual(days.map(\.day), [
            ClaudeLimitsReport.parseDate("2026-10-13T21:00:00Z")!,
            ClaudeLimitsReport.parseDate("2026-10-12T21:00:00Z")!,
        ])
        XCTAssertTrue(days[0].sessions.isEmpty)
        XCTAssertEqual(days[0].spentUSD, 0)
        XCTAssertEqual(days[0].carryOver?.spentUSD, 120)
    }

    /// A midnight from a CLI in another time zone, and a carry-over that
    /// would show as "+$0", are left out.
    func testCarryOverIsLeftOutInAnotherTimeZoneAndUnderFiftyCents() throws {
        let report = try ClaudeLimitsFixture.report(afterMidnight: "2026-10-13T21:00:00.000Z", spentUSD: 120)
        let utcDays = ClaudeSessionDay.days(report.sessions, calendar: calendar("UTC"))
        XCTAssertEqual(utcDays.count, 2)
        XCTAssertTrue(utcDays.allSatisfy { $0.carryOver == nil })

        let small = try ClaudeLimitsFixture.report(afterMidnight: "2026-10-13T21:00:00.000Z", spentUSD: 0.3)
        XCTAssertTrue(ClaudeSessionDay.days(small.sessions, calendar: calendar("Europe/Istanbul")).allSatisfy { $0.carryOver == nil })
    }

    func testDecodesWithoutAfterMidnight() throws {
        XCTAssertTrue(try report().sessions.allSatisfy { $0.afterMidnight == nil })
        let carried = try ClaudeLimitsFixture.report(afterMidnight: "2026-10-13T21:00:00.000Z", spentUSD: 120)
        XCTAssertEqual(carried.sessions.last?.afterMidnight?.at, ClaudeLimitsReport.parseDate("2026-10-13T21:00:00Z"))
    }
}

final class HourlyTimelineTests: XCTestCase {
    private func timeline(_ points: [(String, Double, [(String, Double)])]) -> GranularTimeline {
        GranularTimeline(
            bucketMinutes: 15,
            modelSeries: [],
            sessionSeries: [
                .init(id: "session_0", label: "api-server", sessionId: "a"),
                .init(id: "session_1", label: "web", sessionId: "b"),
                .init(id: "session_other", label: "Other", sessionId: nil),
            ],
            points: points.map { timestamp, cost, sessions in
                .init(timestamp: timestamp, cost: cost, tokens: cost * 1000, models: [],
                      sessions: sessions.map { .init(seriesId: $0.0, cost: $0.1, tokens: $0.1 * 1000) })
            }
        )
    }

    private func calendar(_ zone: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        return c
    }

    func testBucketsFifteenMinutePointsByLocalHour() {
        let cal = calendar("Europe/Istanbul")
        let day = ISO8601DateFormatter().date(from: "2026-10-14T09:00:00Z")!
        let hours = HourlyTimeline.buckets(
            timeline: timeline([
                ("2026-10-14T08:00:00.000Z", 1, [("session_0", 1)]),
                ("2026-10-14T08:15:00.000Z", 2, [("session_1", 2)]),
                ("2026-10-14T08:45:00.000Z", 3, [("session_0", 3)]),
                ("2026-10-14T09:00:00.000Z", 5, [("session_other", 5)]),
                ("2026-10-13T20:45:00.000Z", 9, [("session_0", 9)]),
            ]),
            day: day,
            calendar: cal
        )
        XCTAssertEqual(hours.count, 24)
        // 08:00Z is 11:00 in Istanbul.
        XCTAssertEqual(hours[11].cost, 6)
        XCTAssertEqual(hours[11].topChats.map(\.label), ["api-server", "web"])
        XCTAssertEqual(hours[11].topChats.first?.cost, 4)
        XCTAssertEqual(hours[12].topChats.map(\.label), ["Other"])
        XCTAssertEqual(hours.reduce(0) { $0 + $1.cost }, 11, "yesterday's point is not today's")
    }

    func testDaylightSavingDaysHaveTwentyThreeAndTwentyFiveHours() {
        let cal = calendar("America/New_York")
        let spring = ISO8601DateFormatter().date(from: "2026-03-08T16:00:00Z")!
        let fall = ISO8601DateFormatter().date(from: "2026-11-01T16:00:00Z")!
        XCTAssertEqual(HourlyTimeline.buckets(timeline: nil, day: spring, calendar: cal).count, 23)
        XCTAssertEqual(HourlyTimeline.buckets(timeline: nil, day: fall, calendar: cal).count, 25)
    }
}
