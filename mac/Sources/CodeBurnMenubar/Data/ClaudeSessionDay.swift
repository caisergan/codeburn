import Foundation

/// A day of the Sessions list: the sessions that started on it, newest first,
/// and the part of a session from the day before that was spent after its
/// midnight. The rows add up to `spentUSD`; the carry-over is what the
/// calendar day adds on top, so today's two together match the headline.
struct ClaudeSessionDay: Equatable {
    struct CarryOver: Equatable {
        let session: ClaudeLimitsReport.Session
        let spentUSD: Double

        /// The part of the session's spend after midnight, 0...1.
        var share: Double {
            session.spentUSD > 0 ? min(1, max(0, spentUSD / session.spentUSD)) : 0
        }
    }

    let day: Date
    let sessions: [ClaudeLimitsReport.Session]
    let carryOver: CarryOver?

    var spentUSD: Double { sessions.reduce(0) { $0 + $1.spentUSD } }
    var unpriced: Bool { sessions.contains { !$0.unpricedModels.isEmpty } }

    /// Below this a carry-over shows as "+$0", so it is left out.
    static let minimumCarryOverUSD = 0.5

    /// Days newest first, like the sessions. A day no session started on still
    /// gets a group when a session carried into it, so the small hours of
    /// today are never missing. A carry-over whose midnight is not a midnight
    /// in `calendar` (the CLI ran in another time zone) is left out.
    static func days(_ sessions: [ClaudeLimitsReport.Session], calendar: Calendar = .current) -> [ClaudeSessionDay] {
        var started: [Date: [ClaudeLimitsReport.Session]] = [:]
        for session in sessions {
            started[calendar.startOfDay(for: session.start), default: []].append(session)
        }
        var carried: [Date: CarryOver] = [:]
        for session in sessions {
            guard let after = session.afterMidnight,
                  after.spentUSD >= minimumCarryOverUSD,
                  calendar.startOfDay(for: after.at) == after.at,
                  calendar.startOfDay(for: session.start) < after.at,
                  carried[after.at] == nil
            else { continue }
            carried[after.at] = CarryOver(session: session, spentUSD: after.spentUSD)
        }
        return Set(started.keys).union(carried.keys)
            .sorted(by: >)
            .map { ClaudeSessionDay(day: $0, sessions: started[$0] ?? [], carryOver: carried[$0]) }
    }
}
