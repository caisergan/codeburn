import Foundation

/// Persisted snapshot of a single utilization reading. We capture one per window every time
/// SubscriptionClient.fetch() succeeds so we can answer "what did the prior 7-day cycle finish at?"
/// when the current window has no usable data yet (just reset).
struct SubscriptionSnapshot: Codable, Sendable {
    let windowKey: String        // "five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"
    let percent: Double          // 0..100
    let resetsAt: Date           // resets_at active at capture (identifies which window cycle this belongs to)
    let capturedAt: Date         // when the snapshot was recorded
    let effectiveTokens: Double? // tokens consumed in window at capture (nil if not computed)
}

private let snapshotFilename = "subscription-snapshots.json"
private let pruneOlderThanSeconds: TimeInterval = 30 * 24 * 3600

func subscriptionSnapshotsPath() -> String {
    return (CodeBurnCacheDirectory.resolve() as NSString).appendingPathComponent(snapshotFilename)
}

private actor SnapshotLock {
    static let shared = SnapshotLock()
    func run<T>(_ fn: () throws -> T) rethrows -> T { try fn() }
}

enum SubscriptionSnapshotStore {
    /// Append a snapshot. Auto-prunes entries older than 30 days. Idempotent: if a snapshot
    /// with the same windowKey + resetsAt already exists, only update percent if new is higher
    /// (so "final" reading near reset is preserved).
    static func record(_ snapshot: SubscriptionSnapshot, path: String = subscriptionSnapshotsPath(), now: Date = Date()) async {
        await SnapshotLock.shared.run {
            do {
                // A file that exists but cannot be read or decoded right now
                // must not be replaced by this one snapshot: leave it alone and
                // let the next fetch try again.
                guard var all = loadAllForUpdate(path: path) else { return }
                let key = rowKey(snapshot)
                if let idx = all.firstIndex(where: { rowKey($0) == key }) {
                    if snapshot.percent > all[idx].percent {
                        all[idx] = snapshot
                    }
                } else {
                    all.append(snapshot)
                }
                let cutoff = now.addingTimeInterval(-pruneOlderThanSeconds)
                all = all.filter { $0.capturedAt >= cutoff }
                try save(all, to: path)
            } catch {
                NSLog("CodeBurn: snapshot record failed: \(error)")
            }
        }
    }

    /// Returns the final percent of the immediately-prior cycle for this window, or nil if no
    /// prior data is available. Logic: among snapshots whose resetsAt < currentResetsAt, pick
    /// the group with the largest resetsAt (most recent prior cycle), then return the max
    /// percent in that group (the closest-to-final reading we have).
    static func previousWindowFinal(windowKey: String, currentResetsAt: Date) async -> Double? {
        await SnapshotLock.shared.run {
            let all = loadAll()
            let current = normalizedResetTime(currentResetsAt)
            let priors = all.filter { $0.windowKey == windowKey && normalizedResetTime($0.resetsAt) < current }
            guard let mostRecentPriorReset = priors.map({ normalizedResetTime($0.resetsAt) }).max() else { return nil }
            let priorWindow = priors.filter { normalizedResetTime($0.resetsAt) == mostRecentPriorReset }
            return priorWindow.map(\.percent).max()
        }
    }

    /// Return all snapshots for a given window key, useful for capacity estimation.
    static func snapshots(for windowKey: String) async -> [SubscriptionSnapshot] {
        await SnapshotLock.shared.run {
            loadAll().filter { $0.windowKey == windowKey }
        }
    }

    /// Test seam: clear all snapshots.
    static func resetForTesting() async {
        await clearAll()
    }

    /// Wipe all snapshots from disk. Called when the user disconnects so the
    /// "Based on last cycle" projections do not contaminate a reconnect under
    /// a different account or tier.
    static func clearAll() async {
        await SnapshotLock.shared.run {
            try? FileManager.default.removeItem(atPath: subscriptionSnapshotsPath())
        }
    }

    // MARK: - Internals

    /// One row per window cycle. The reset time jitters by up to a second
    /// between fetches (07:59:59.6 against 08:00:00.0), and the file stores
    /// whole seconds, so the exact value never matched a stored row: every
    /// fetch appended. Windows start on 10-minute marks, so that is the key.
    static func rowKey(_ snapshot: SubscriptionSnapshot) -> String {
        "\(snapshot.windowKey)|\(Int(normalizedResetTime(snapshot.resetsAt).timeIntervalSince1970))"
    }

    static func normalizedResetTime(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 600).rounded() * 600)
    }

    private static func loadAll() -> [SubscriptionSnapshot] {
        loadAllForUpdate() ?? []
    }

    /// The stored rows, `[]` when there is no file yet, and nil when the file
    /// exists but could not be read or decoded, so a writer can tell "empty"
    /// from "unreadable" and never overwrite history it failed to load.
    static func loadAllForUpdate(path: String = subscriptionSnapshotsPath()) -> [SubscriptionSnapshot]? {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        guard let data = try? SafeFile.read(from: path) else {
            NSLog("CodeBurn: snapshot file unreadable; leaving it untouched")
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let rows = try? decoder.decode([SubscriptionSnapshot].self, from: data) else {
            NSLog("CodeBurn: snapshot file did not decode; leaving it untouched")
            return nil
        }
        return rows
    }

    private static func save(_ snapshots: [SubscriptionSnapshot], to path: String = subscriptionSnapshotsPath()) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshots)
        // SafeFile.write refuses symlinked targets and does the tmp+rename atomic dance.
        try SafeFile.write(data, to: path, mode: 0o600)
    }
}
