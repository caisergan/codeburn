import Foundation

/// Append-only record of every check of Claude's usage endpoint, the input
/// `codeburn limits` turns into per-session and per-week numbers.
///
/// Every check is logged, failures included with a reason, so the CLI can tell
/// a gap in the readings from "nothing changed". One JSON object per line in
/// `claude-limit-readings.jsonl` in the CodeBurn cache directory, mode 0600,
/// each line written with one `O_APPEND` write so a concurrent reader never
/// sees half a line. Lines older than 35 days are pruned once a day by
/// rewriting the file through `SafeFile.write`.
actor ClaudeLimitReadingLog {
    static let shared = ClaudeLimitReadingLog()

    static let filename = "claude-limit-readings.jsonl"
    static let retentionSeconds: TimeInterval = 35 * 24 * 3600
    static let pruneIntervalSeconds: TimeInterval = 24 * 3600
    /// Set once the old snapshot store's rows have been copied in, so history
    /// from before this log existed is kept exactly once.
    static let importedDefaultsKey = "codeburn.claudeSessions.importedSnapshots"

    enum FailureReason: String, Sendable {
        case rateLimited = "rate_limited"
        case auth
        case network
        case decode
        case noWindows = "no_windows"
    }

    let path: String
    private let defaults: UserDefaults
    private var lastPruneAt: Date?

    /// `defaultsSuite` is a test seam: nil is the app's own domain.
    init(
        path: String = (CodeBurnCacheDirectory.resolve() as NSString).appendingPathComponent(ClaudeLimitReadingLog.filename),
        defaultsSuite: String? = nil
    ) {
        self.path = path
        self.defaults = defaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    // MARK: - Recording

    func recordSuccess(_ usage: SubscriptionUsage, at now: Date = Date()) {
        guard usage.fiveHourPercent != nil || usage.sevenDayPercent != nil else {
            recordFailure(.noWindows, retryAfter: nil, at: now)
            return
        }
        append([Self.successLine(usage, at: now)])
        pruneIfDue(now: now)
    }

    func recordFailure(_ reason: FailureReason, retryAfter: Int?, at now: Date = Date()) {
        append([Self.failureLine(reason, retryAfter: retryAfter, at: now)])
    }

    func recordFailure(_ error: Error, at now: Date = Date()) {
        let (reason, retryAfter) = Self.classify(error, now: now)
        recordFailure(reason, retryAfter: retryAfter, at: now)
    }

    /// Copies `subscription-snapshots.json` in as readings, once. Those rows
    /// only recorded rises, so they are marked `imported` and the CLI never
    /// reads a missing imported row as "unchanged". An unreadable snapshot file
    /// is retried on the next launch rather than marked done.
    func importSnapshotsIfNeeded(from snapshotsPath: String = subscriptionSnapshotsPath(), now: Date = Date()) {
        guard !defaults.bool(forKey: Self.importedDefaultsKey) else { return }
        guard let rows = SubscriptionSnapshotStore.loadAllForUpdate(path: snapshotsPath) else { return }
        let lines = Self.importLines(rows, now: now)
        if !lines.isEmpty { append(lines) }
        defaults.set(true, forKey: Self.importedDefaultsKey)
    }

    // MARK: - Lines

    // ISO8601DateFormatter is documented thread-safe once configured.
    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func iso(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    private static func window(_ percent: Double?, _ resetsAt: Date?) -> [String: Any]? {
        guard let percent, percent.isFinite else { return nil }
        var row: [String: Any] = ["pct": percent]
        row["resetsAt"] = resetsAt.map(iso) ?? NSNull()
        return row
    }

    static func successLine(_ usage: SubscriptionUsage, at now: Date) -> [String: Any] {
        var line: [String: Any] = ["at": iso(now), "ok": true, "plan": usage.tier.displayName]
        if let five = window(usage.fiveHourPercent, usage.fiveHourResetsAt) { line["five_hour"] = five }
        if let week = window(usage.sevenDayPercent, usage.sevenDayResetsAt) { line["seven_day"] = week }
        var scoped: [[String: Any]] = []
        if let opus = window(usage.sevenDayOpusPercent, usage.sevenDayOpusResetsAt) {
            scoped.append(opus.merging(["label": "Weekly · Opus"]) { $1 })
        }
        if let sonnet = window(usage.sevenDaySonnetPercent, usage.sevenDaySonnetResetsAt) {
            scoped.append(sonnet.merging(["label": "Weekly · Sonnet"]) { $1 })
        }
        for model in usage.scopedWeekly {
            if let row = window(model.percent, model.resetsAt) {
                scoped.append(row.merging(["label": "Weekly · \(model.label)"]) { $1 })
            }
        }
        if !scoped.isEmpty { line["scoped"] = scoped }
        return line
    }

    static func failureLine(_ reason: FailureReason, retryAfter: Int?, at now: Date) -> [String: Any] {
        var line: [String: Any] = ["at": iso(now), "ok": false, "reason": reason.rawValue]
        if let retryAfter { line["retryAfter"] = retryAfter }
        return line
    }

    /// One reading per capture instant: the old store wrote the 5-hour and
    /// weekly rows of one fetch with the same `capturedAt`.
    static func importLines(_ rows: [SubscriptionSnapshot], now: Date) -> [[String: Any]] {
        let cutoff = now.addingTimeInterval(-retentionSeconds)
        var byInstant: [Date: [String: Any]] = [:]
        for row in rows where row.capturedAt >= cutoff {
            let key: String
            switch row.windowKey {
            case "five_hour": key = "five_hour"
            case "seven_day": key = "seven_day"
            default: continue
            }
            var line = byInstant[row.capturedAt] ?? ["at": iso(row.capturedAt), "ok": true, "imported": true]
            line[key] = ["pct": row.percent, "resetsAt": iso(row.resetsAt)]
            byInstant[row.capturedAt] = line
        }
        return byInstant.keys.sorted().compactMap { byInstant[$0] }
    }

    static func classify(_ error: Error, now: Date) -> (FailureReason, Int?) {
        guard let fetch = error as? ClaudeSubscriptionService.FetchError else { return (.network, nil) }
        switch fetch {
        case let .rateLimited(retryAt):
            return (.rateLimited, max(0, Int(retryAt.timeIntervalSince(now).rounded())))
        case .usageDecodeFailed:
            return (.decode, nil)
        case .network:
            return (.network, nil)
        case let .usageHTTPError(code, _):
            return (code == 401 || code == 403 ? .auth : .network, nil)
        case .notBootstrapped, .bootstrapFailed, .credential:
            return (.auth, nil)
        }
    }

    static func encode(_ lines: [[String: Any]]) -> Data {
        var data = Data()
        for line in lines {
            guard JSONSerialization.isValidJSONObject(line),
                  let encoded = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys, .withoutEscapingSlashes])
            else { continue }
            data.append(encoded)
            data.append(0x0A)
        }
        return data
    }

    // MARK: - File

    private func append(_ lines: [[String: Any]]) {
        let data = Self.encode(lines)
        guard !data.isEmpty else { return }
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            NSLog("CodeBurn: limit reading log open failed: errno %d", errno)
            return
        }
        defer { close(fd) }
        let written = data.withUnsafeBytes { buffer in
            write(fd, buffer.baseAddress, buffer.count)
        }
        if written != data.count {
            NSLog("CodeBurn: limit reading log short write (%d of %d)", written, data.count)
        }
    }

    func pruneIfDue(now: Date = Date()) {
        if let lastPruneAt, now.timeIntervalSince(lastPruneAt) < Self.pruneIntervalSeconds { return }
        lastPruneAt = now
        guard FileManager.default.fileExists(atPath: path),
              let data = try? SafeFile.read(from: path, maxBytes: 64 * 1024 * 1024),
              let text = String(data: data, encoding: .utf8) else { return }
        let cutoff = now.addingTimeInterval(-Self.retentionSeconds)
        var kept: [Substring] = []
        var dropped = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let at = Self.lineTime(line), at < cutoff {
                dropped += 1
            } else {
                kept.append(line)
            }
        }
        guard dropped > 0 else { return }
        let rewritten = kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n"
        do {
            try SafeFile.write(Data(rewritten.utf8), to: path, mode: 0o600)
        } catch {
            NSLog("CodeBurn: limit reading log prune failed: \(error)")
        }
    }

    /// The line's `at`, or nil for a malformed line (kept: pruning is not the
    /// place to decide what the CLI may read).
    static func lineTime(_ line: Substring) -> Date? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let at = object["at"] as? String else { return nil }
        if let date = isoFormatter.date(from: at) { return date }
        let plain = ISO8601DateFormatter()
        return plain.date(from: at)
    }
}
