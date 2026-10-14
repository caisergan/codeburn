import Foundation

/// Scheduling decisions for the live quota refresh, kept out of the
/// AppKit-bound refresh loop so they are testable on their own.
enum QuotaRefreshDecision {
    /// The CLI payload half of a tick is gated on local session-file mtimes.
    /// Quota is server-side state (window resets, usage from other machines),
    /// so a tick whose payload was skipped as unchanged still owes the quota
    /// half a run; it self-throttles on SubscriptionRefreshCadence.
    static func needsQuotaOnlyTick(payloadRefreshDue: Bool, payloadSkippedUnchanged: Bool) -> Bool {
        payloadRefreshDue && payloadSkippedUnchanged
    }

    static func isDue(
        force: Bool,
        autoRefreshAllowed: Bool,
        lastAttemptAt: Date?,
        now: Date,
        threshold: TimeInterval
    ) -> Bool {
        if force { return true }
        guard autoRefreshAllowed else { return false }
        return now.timeIntervalSince(lastAttemptAt ?? .distantPast) >= threshold
    }

    /// True when a window's `resetsAt` fell between the previous tick and now.
    /// That boundary is the one moment the provider's numbers are certain to
    /// have moved, and it fires once per reset instant: the tick that sees it
    /// moves `lastCheckedAt` past the boundary.
    static func windowRolledOver(resetDates: [Date], lastCheckedAt: Date, now: Date) -> Bool {
        resetDates.contains { $0 > lastCheckedAt && $0 <= now }
    }

    /// Claude counts as working for this long after its last transcript write.
    /// The same span is the tail that captures the final values after the
    /// last call.
    static let claudeActiveWindowSeconds: TimeInterval = 10 * 60

    /// How often limits are read while Claude is working.
    static func claudeLiveReadingInterval(lowPowerMode: Bool) -> TimeInterval {
        lowPowerMode ? 5 * 60 : 2 * 60
    }

    /// The refresh loop ticks every 30 seconds with a little leeway, so an
    /// interval measured to the second would slip a whole tick every time.
    static let claudeLiveReadingSlackSeconds: TimeInterval = 5

    /// True when a background Claude limit reading is owed: the setting is on,
    /// Claude is connected, a transcript was written within the active window,
    /// no failure back-off is pending, and the last attempt is an interval old.
    /// Independent of the usage refresh cadence, Manual included; while idle it
    /// is always false and the existing cadence applies unchanged.
    static func claudeLiveReadingDue(
        enabled: Bool,
        connected: Bool,
        lastClaudeWriteAt: Date?,
        lastAttemptAt: Date?,
        backoffUntil: Date?,
        lowPowerMode: Bool,
        now: Date
    ) -> Bool {
        guard enabled, connected, let lastClaudeWriteAt else { return false }
        guard now.timeIntervalSince(lastClaudeWriteAt) <= claudeActiveWindowSeconds else { return false }
        if let backoffUntil, now < backoffUntil { return false }
        let interval = claudeLiveReadingInterval(lowPowerMode: lowPowerMode)
        return now.timeIntervalSince(lastAttemptAt ?? .distantPast) >= interval - claudeLiveReadingSlackSeconds
    }
}
