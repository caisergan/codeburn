import Foundation

/// `codeburn limits --format json`: Claude 5-hour sessions and weeks at API
/// prices against limit use. The CLI owns all of the math; this is its output.
struct ClaudeLimitsReport: Decodable, Equatable, Sendable {
    enum Quality: String, Decodable, Sendable {
        case exact, measured, lowerBound, estimated, unknown

        /// `≈` estimated, `≥` lower bound, nothing for measured or exact.
        var mark: String {
            switch self {
            case .estimated: "≈"
            case .lowerBound: "≥"
            case .exact, .measured, .unknown: ""
            }
        }

        var isKnown: Bool { self != .unknown }

        /// Spoken form for VoiceOver.
        var spoken: String {
            switch self {
            case .exact: L("exact")
            case .measured: L("measured")
            case .lowerBound: L("at least")
            case .estimated: L("estimated")
            case .unknown: L("unknown")
            }
        }

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Quality(rawValue: raw) ?? .unknown
        }
    }

    struct Tokens: Decodable, Equatable, Sendable {
        let input: Double
        let output: Double
        let cacheRead: Double
        let cacheWrite: Double

        var total: Double { input + output + cacheRead + cacheWrite }
    }

    struct Chat: Decodable, Equatable, Sendable, Identifiable {
        let sessionId: String
        let title: String
        let spentUSD: Double
        var id: String { sessionId }
    }

    struct RanOut: Decodable, Equatable, Sendable {
        enum Limit: String, Decodable, Sendable { case fiveHour = "five_hour", sevenDay = "seven_day" }
        let limit: Limit
        let at: Date
        let spentUSD: Double
    }

    struct Gap: Decodable, Equatable, Sendable {
        let from: Date
        let to: Date
        let reason: String
    }

    struct WeekSplit: Decodable, Equatable, Sendable {
        let thisWeek: Double?
        let lastWeek: Double?
        let resetAt: Date
    }

    struct Session: Decodable, Equatable, Sendable, Identifiable {
        let id: String
        let start: Date
        let end: Date
        let startInferred: Bool
        let running: Bool
        let spentUSD: Double
        let tokens: Tokens
        let fiveHourPct: Double?
        let fiveHourQuality: Quality
        let weekPct: Double?
        let weekQuality: Quality
        let weekSplit: WeekSplit?
        let weekFrom: Double?
        let weekTo: Double?
        let fullSessionUSD: Double?
        let fullSessionQuality: Quality
        let ranOut: RanOut?
        let outsideThisMac: Bool
        let unpricedModels: [String]
        let chats: [Chat]
        let gap: Gap?
    }

    struct Week: Decodable, Equatable, Sendable, Identifiable {
        enum EndReason: String, Decodable, Sendable {
            case reset, earlyReset = "early_reset", moved, inferred, running

            init(from decoder: Decoder) throws {
                let raw = try decoder.singleValueContainer().decode(String.self)
                self = EndReason(rawValue: raw) ?? .reset
            }
        }

        let start: Date
        let end: Date
        let endReason: EndReason
        let startInferred: Bool
        let running: Bool
        let spentUSD: Double
        let tokens: Tokens
        let usedPct: Double?
        let usedQuality: Quality
        let fullWeekUSD: Double?
        let fullWeekQuality: Quality
        let ranOutAt: Date?
        let unpricedModels: [String]

        var id: Date { start }
    }

    struct Current: Decodable, Equatable, Sendable {
        let session: Session?
        let week: Week?
    }

    struct Rate: Decodable, Equatable, Sendable {
        /// Week points per 5-hour point; a full session is `100 ×` this.
        let weekPerSessionPoint: Double?
        let basis: Int
        let restartedAt: Date?
    }

    let generatedAt: Date
    let plan: String?
    let readingsThrough: Date?
    let current: Current
    let rate: Rate
    let sessionsLeft: Int?
    let runsOutFirstAtSessionPct: Double?
    let sessions: [Session]
    let weeks: [Week]
    let gaps: [Gap]

    /// A full 5-hour session as a share of the week, in percent.
    var fullSessionWeekShare: Double? {
        rate.weekPerSessionPoint.map { $0 * 100 }
    }

    static func decode(_ data: Data) throws -> ClaudeLimitsReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = parseDate(raw) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(raw)"))
        }
        return try decoder.decode(ClaudeLimitsReport.self, from: data)
    }

    static func parseDate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }
}
