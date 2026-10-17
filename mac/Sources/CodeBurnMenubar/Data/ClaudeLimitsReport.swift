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

    struct Prompt: Decodable, Equatable, Sendable, Hashable {
        let at: Date
        let text: String
    }

    struct Chat: Decodable, Equatable, Sendable, Identifiable {
        let sessionId: String
        let title: String
        let spentUSD: Double
        /// Missing from CLIs older than the chat prompts.
        let project: String?
        let path: String?
        let firstAt: Date?
        let lastAt: Date?
        let promptCount: Int?
        /// The first prompts typed in this session; `promptCount` counts all.
        let prompts: [Prompt]?
        var id: String { sessionId }
    }

    struct Model: Decodable, Equatable, Sendable, Identifiable {
        let model: String
        let spentUSD: Double
        let tokens: Double
        var id: String { model }
    }

    /// One slice of a session (an hour) or of a week (24 hours from its
    /// reset). `pct` is the highest reading taken by the slice's end; nil
    /// when no reading fell inside it.
    struct Slice: Decodable, Equatable, Sendable, Identifiable {
        let start: Date
        let end: Date
        let spentUSD: Double
        let tokens: Double
        let pct: Double?
        var id: Date { start }

        private enum CodingKeys: String, CodingKey { case start, end, spentUSD, tokens, fiveHourPct, usedPct }

        init(start: Date, end: Date, spentUSD: Double, tokens: Double, pct: Double?) {
            self.start = start
            self.end = end
            self.spentUSD = spentUSD
            self.tokens = tokens
            self.pct = pct
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            start = try c.decode(Date.self, forKey: .start)
            end = try c.decode(Date.self, forKey: .end)
            spentUSD = try c.decode(Double.self, forKey: .spentUSD)
            tokens = try c.decode(Double.self, forKey: .tokens)
            pct = try c.decodeIfPresent(Double.self, forKey: .fiveHourPct) ?? c.decodeIfPresent(Double.self, forKey: .usedPct)
        }
    }

    /// A session as one block of a week.
    struct WeekSession: Decodable, Equatable, Sendable, Identifiable {
        let id: String
        let start: Date
        let end: Date
        let running: Bool
        let spentUSD: Double
        let weekPct: Double?
        let weekQuality: Quality
    }

    struct SamePoint: Decodable, Equatable, Sendable {
        let at: Date
        let spentUSD: Double
        let usedPct: Double?
        let usedQuality: Quality
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

    /// The local midnight inside a session and what it spent after it.
    struct AfterMidnight: Decodable, Equatable, Sendable {
        let at: Date
        let spentUSD: Double
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
        /// Missing from CLIs older than the tabbed detail.
        let models: [Model]?
        let hours: [Slice]?
        /// Missing when the session stays inside one day, and from older CLIs.
        let afterMidnight: AfterMidnight?
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
        /// Missing from CLIs older than the tabbed detail.
        let models: [Model]?
        let days: [Slice]?
        /// Oldest first.
        let sessions: [WeekSession]?
        let previousAtSamePoint: SamePoint?

        var id: Date { start }
    }

    struct FullWeekAverage: Decodable, Equatable, Sendable {
        let usd: Double?
        let basis: Int
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
    let fullWeekAverage: FullWeekAverage?
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
