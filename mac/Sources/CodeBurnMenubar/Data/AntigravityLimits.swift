import Foundation

/// `codeburn limits --provider antigravity --format json`: Antigravity 5-hour
/// sessions and weeks at API prices, one report per quota group. Each group's
/// report has the shape of Claude's, so the Sessions | Weeks views render it
/// unchanged. See docs/design/antigravity-session-usage.md.
struct AntigravityLimitsReport: Decodable, Equatable, Sendable {
    struct Group: Decodable, Equatable, Sendable, Identifiable {
        /// The bucket id prefix: "gemini", "3p".
        let id: String
        /// "Gemini Models", "Claude and GPT models".
        let name: String
        let models: [String]
        let report: ClaudeLimitsReport

        /// The name without its trailing "Models", for the group switch.
        var shortName: String {
            let trimmed = name.replacingOccurrences(of: #"\s+models?$"#, with: "", options: [.regularExpression, .caseInsensitive])
            return trimmed.isEmpty ? name : trimmed
        }

        /// Whether the group has anything to show: a session, or a week with
        /// spend or use.
        var hasActivity: Bool {
            !report.sessions.isEmpty || report.weeks.contains { $0.spentUSD > 0 || ($0.usedPct ?? 0) >= 1 }
        }

        /// When the group was last used, for picking the group shown first.
        var lastActiveAt: Date? {
            report.sessions.map { $0.running ? Date.distantFuture : $0.end }.max()
        }
    }

    let generatedAt: Date
    let plan: String?
    let readingsThrough: Date?
    let groups: [Group]

    /// The groups worth a switch: those with activity, else the first one.
    var shownGroups: [Group] {
        let active = groups.filter(\.hasActivity)
        if !active.isEmpty { return active }
        return groups.first.map { [$0] } ?? []
    }

    /// The group with a running session, else the one used last.
    var defaultGroupID: String? {
        shownGroups.max { ($0.lastActiveAt ?? .distantPast) < ($1.lastActiveAt ?? .distantPast) }?.id
    }

    static func decode(_ data: Data) throws -> AntigravityLimitsReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = ClaudeLimitsReport.parseDate(raw) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(raw)"))
        }
        return try decoder.decode(AntigravityLimitsReport.self, from: data)
    }
}

/// Every Antigravity quota check, appended to
/// `antigravity-limit-readings.jsonl` in the CodeBurn cache directory with the
/// same file rules as Claude's log (0600, one `O_APPEND` write per line, 35-day
/// pruning). Each line holds every group's 5-hour and weekly bucket as percent
/// used; the CLI drops idle buckets, whose reset keeps sliding.
enum AntigravityLimitReadingLog {
    static let filename = "antigravity-limit-readings.jsonl"

    static let shared = ClaudeLimitReadingLog(
        path: (CodeBurnCacheDirectory.resolve() as NSString).appendingPathComponent(filename)
    )

    // ISO8601DateFormatter is documented thread-safe once configured.
    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func bucket(_ bucket: AntigravityUsage.Group.Bucket?) -> [String: Any]? {
        guard let bucket, bucket.remainingFraction.isFinite else { return nil }
        // Two decimals: Google reports fractions such as 0.99, and 1 − 0.99
        // would otherwise log as 1.0000000000000009.
        let used = (bucket.usedPercent * 100).rounded() / 100
        return ["pct": used, "resetsAt": bucket.resetsAt.map(isoFormatter.string(from:)) ?? NSNull()]
    }

    /// The line for one successful read, or nil when the payload had no
    /// groups (the legacy per-model status payload).
    static func successLine(_ usage: AntigravityUsage, at now: Date) -> [String: Any]? {
        guard !usage.groups.isEmpty else { return nil }
        var line: [String: Any] = ["at": isoFormatter.string(from: now), "ok": true, "source": usage.source == .local ? "local" : "remote"]
        if let plan = usage.plan, !plan.isEmpty { line["plan"] = plan }
        line["groups"] = usage.groups.map { group -> [String: Any] in
            var row: [String: Any] = ["id": group.id, "name": group.name, "models": group.models]
            if let five = bucket(group.fiveHour) { row["five_hour"] = five }
            if let week = bucket(group.weekly) { row["seven_day"] = week }
            return row
        }
        return line
    }

    static func record(_ usage: AntigravityUsage, at now: Date = Date(), log: ClaudeLimitReadingLog = shared) async {
        if let line = successLine(usage, at: now) {
            await log.recordLine(line, at: now)
        } else {
            await log.recordFailure(.noWindows, retryAfter: nil, at: now)
        }
    }

    /// No sign-in at all is the routine "not connected" state, not a gap in
    /// readings, so it is not logged.
    static func failureReason(_ error: Error) -> ClaudeLimitReadingLog.FailureReason? {
        guard let fetch = error as? AntigravitySubscriptionService.FetchError else { return .network }
        switch fetch {
        case .disconnected: return nil
        case .signedOut: return .auth
        case .network, .remote: return .network
        }
    }

    static func recordFailure(_ error: Error, at now: Date = Date()) async {
        guard !(error is CancellationError), let reason = failureReason(error) else { return }
        await shared.recordFailure(reason, retryAfter: nil, at: now)
    }
}

/// "Keep Antigravity session numbers live while Antigravity is working". On
/// by default, like Claude's: quota is read every 2 minutes (5 in Low Power
/// Mode) while a conversation was written in the last 10 minutes, and for 10
/// minutes after.
enum AntigravityLiveReadingPreference {
    static let defaultsKey = "codeburn.antigravitySessions.liveWhileActive"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? true
    }
}

/// Where Antigravity writes its conversations: the app, `agy` and the IDE.
enum AntigravityActivity {
    static let monitor = ClaudeActivityMonitor(
        label: "org.agentseal.codeburn.antigravity-activity",
        suffixes: [".db", ".db-wal", ".pb"]
    )

    static func watchedDirectories(homeDirectory: String = NSHomeDirectory()) -> [String] {
        let gemini = (homeDirectory as NSString).appendingPathComponent(".gemini")
        return ["antigravity", "antigravity-cli", "antigravity-ide"]
            .map { (gemini as NSString).appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }
}
