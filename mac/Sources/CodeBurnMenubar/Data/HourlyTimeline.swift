import Foundation

/// Trend › Hours: today's calls by local hour, summed from the payload's
/// 15-minute timeline. A daylight-saving change day has 23 or 25 hours, and
/// the two repeated hours of a fall-back night stay separate bars.
struct HourBucket: Equatable, Sendable, Identifiable {
    struct Chat: Equatable, Sendable {
        let label: String
        let cost: Double
        let tokens: Double
    }

    let start: Date
    let end: Date
    var cost: Double
    var tokens: Double
    /// Top chats by cost in this hour, at most three.
    var topChats: [Chat]

    var id: Date { start }
}

enum HourlyTimeline {
    static func buckets(
        timeline: GranularTimeline?,
        day: Date,
        calendar: Calendar = .current
    ) -> [HourBucket] {
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }

        var hours: [HourBucket] = []
        var cursor = dayStart
        while cursor < dayEnd {
            // Adding hours to an absolute instant steps through a DST change
            // correctly: 23 steps on a spring-forward day, 25 on fall-back.
            let next = min(cursor.addingTimeInterval(3600), dayEnd)
            hours.append(HourBucket(start: cursor, end: next, cost: 0, tokens: 0, topChats: []))
            cursor = next
        }
        guard let timeline, !hours.isEmpty else { return hours }

        let labels = Dictionary(timeline.sessionSeries.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
        var chats: [[String: (cost: Double, tokens: Double)]] = Array(repeating: [:], count: hours.count)
        for point in timeline.points {
            guard let at = ClaudeLimitsReport.parseDate(point.timestamp), at >= dayStart, at < dayEnd else { continue }
            let index = min(Int(at.timeIntervalSince(dayStart) / 3600), hours.count - 1)
            hours[index].cost += point.cost
            hours[index].tokens += point.tokens
            for value in point.sessions {
                let current = chats[index][value.seriesId] ?? (0, 0)
                chats[index][value.seriesId] = (current.cost + value.cost, current.tokens + value.tokens)
            }
        }
        for index in hours.indices {
            hours[index].topChats = chats[index]
                .filter { $0.value.cost > 0 || $0.value.tokens > 0 }
                .sorted { lhs, rhs in
                    lhs.value.cost != rhs.value.cost ? lhs.value.cost > rhs.value.cost : lhs.key < rhs.key
                }
                .prefix(3)
                .map { HourBucket.Chat(label: labels[$0.key] ?? L("Other"), cost: $0.value.cost, tokens: $0.value.tokens) }
        }
        return hours
    }
}
