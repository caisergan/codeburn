import Foundation

/// Text for the Claude session and week numbers, kept free of views and of the
/// main actor so the popover, the All-tab row and the menu-bar second line say
/// the same thing and stay testable. Display rules: whole percents, `≈`
/// estimated, `≥` lower bound, `–` unknown, `⚠︎` a limit ran out.
enum ClaudeSessionFormat {
    typealias Quality = ClaudeLimitsReport.Quality

    static let unknownMark = "–"
    static let ranOutMark = "⚠︎"

    static func percent(_ value: Double?, _ quality: Quality, signed: Bool = false) -> String {
        guard let value, value.isFinite, quality.isKnown else { return unknownMark }
        let whole = Int(value.rounded())
        return "\(quality.mark)\(signed ? "+" : "")\(whole)%"
    }

    /// `$116`, `$1,491`; `$184.87` with `cents`. A spend that includes a model
    /// CodeBurn cannot price is a lower bound: `≥ $116`.
    static func money(_ usd: Double, unpriced: Bool = false, cents: Bool = false, symbol: String, rate: Double) -> String {
        let converted = usd * rate
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.decimalSeparator = "."
        formatter.minimumFractionDigits = cents ? 2 : 0
        formatter.maximumFractionDigits = cents ? 2 : 0
        let digits = formatter.string(from: NSNumber(value: converted)) ?? String(format: cents ? "%.2f" : "%.0f", converted)
        return (unpriced ? "≥ " : "") + symbol + digits
    }

    static func estimatedMoney(_ usd: Double?, _ quality: Quality, symbol: String, rate: Double) -> String {
        guard let usd, quality.isKnown else { return unknownMark }
        let mark = quality == .exact || quality == .measured ? "" : "≈ "
        return mark + money(usd, symbol: symbol, rate: rate)
    }

    static func tokens(_ n: Double) -> String {
        if n >= 1_000_000_000 { return String(format: "%.1fB", n / 1_000_000_000) }
        if n >= 1_000_000 { return String(format: "%.0fM", n / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fK", n / 1_000) }
        return String(format: "%.0f", n)
    }

    // MARK: - Times

    static func clock(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// "Wed" for a day within the coming week.
    static func weekday(_ date: Date, timeZone: TimeZone = .current, locale: Locale = L10n.activeLocale) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f.string(from: date)
    }

    /// "Wed 11:00" for a reset within the coming week.
    static func weekdayClock(_ date: Date, timeZone: TimeZone = .current, locale: Locale = L10n.activeLocale) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.setLocalizedDateFormatFromTemplate("EEE")
        return "\(f.string(from: date)) \(clock(date, timeZone: timeZone))"
    }

    /// "Today 11:00–16:00", "Tue 19:20–00:20", "≈ Tue 19:20–00:20" when the
    /// window was inferred from calls rather than read.
    static func sessionRange(
        start: Date,
        end: Date,
        inferred: Bool,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = L10n.activeLocale
    ) -> String {
        let day: String
        if calendar.isDate(start, inSameDayAs: now) {
            day = L("Today")
        } else {
            let f = DateFormatter()
            f.locale = locale
            f.timeZone = calendar.timeZone
            f.setLocalizedDateFormatFromTemplate("EEE")
            day = f.string(from: start)
        }
        let range = "\(clock(start, timeZone: calendar.timeZone))–\(clock(end, timeZone: calendar.timeZone))"
        return inferred ? "≈ \(day) \(range)" : "\(day) \(range)"
    }

    /// "Oct 7 → Oct 14".
    static func weekRange(start: Date, end: Date, calendar: Calendar = .current, locale: Locale = L10n.activeLocale) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate("MMM d")
        return "\(f.string(from: start)) → \(f.string(from: end))"
    }

    // MARK: - Lines

    /// The Plan view's summary line under the session and week bars.
    static func summaryLine(_ report: ClaudeLimitsReport, timeZone: TimeZone = .current) -> String {
        if let week = report.current.week, let ranOut = week.ranOutAt {
            return L("Week ran out at %1$@ · resets %2$@", clock(ranOut, timeZone: timeZone), weekdayClock(week.end, timeZone: timeZone))
        }
        if let session = report.current.session, let ranOut = session.ranOut {
            switch ranOut.limit {
            case .fiveHour:
                return L("Session ran out at %1$@ · resets %2$@", clock(ranOut.at, timeZone: timeZone), clock(session.end, timeZone: timeZone))
            case .sevenDay:
                let resets = report.current.week.map { weekdayClock($0.end, timeZone: timeZone) } ?? unknownMark
                return L("Week ran out at %1$@ · resets %2$@", clock(ranOut.at, timeZone: timeZone), resets)
            }
        }
        if let at = report.runsOutFirstAtSessionPct {
            return L("Week runs out first, at about %lld%% of this session", Int(at.rounded()))
        }
        guard let share = report.fullSessionWeekShare else {
            return L("Not enough sessions yet to measure")
        }
        return L("A full 5-hour session ≈ %1$lld%% of your week · ≈ %2$lld left", Int(share.rounded()), report.sessionsLeft ?? 0)
    }

    /// The All tab's one-line summary, after its "Claude session" label.
    static func allTabValue(_ report: ClaudeLimitsReport, symbol: String, rate: Double, timeZone: TimeZone = .current) -> String {
        if let session = report.current.session {
            return L(
                "%1$@ · %2$@ · %3$@ of week",
                percent(session.fiveHourPct, session.fiveHourQuality),
                money(session.spentUSD, unpriced: !session.unpricedModels.isEmpty, symbol: symbol, rate: rate),
                percent(session.weekPct, session.weekQuality, signed: true)
            )
        }
        let week = report.current.week
        return L(
            "week %1$@ · resets %2$@",
            percent(week?.usedPct, week?.usedQuality ?? .unknown),
            week.map { weekdayClock($0.end, timeZone: timeZone) } ?? unknownMark
        )
    }

    /// The menu-bar second line: "5h 61% · $116 · wk +8%". Nil with no
    /// session running, so the row hides itself.
    static func menubarRow(_ report: ClaudeLimitsReport?, symbol: String, rate: Double) -> String? {
        guard let session = report?.current.session else { return nil }
        return L(
            "5h %1$@ · %2$@ · wk %3$@",
            percent(session.fiveHourPct, session.fiveHourQuality),
            money(session.spentUSD, unpriced: !session.unpricedModels.isEmpty, symbol: symbol, rate: rate),
            percent(session.weekPct, session.weekQuality, signed: true)
        )
    }

    /// The reason a session's values are estimated, for its expanded row.
    static func gapReason(_ reason: String) -> String {
        switch reason {
        case "rate_limited": L("Anthropic asked CodeBurn to slow down")
        case "auth": L("Claude needed to be reconnected")
        case "decode": L("Anthropic's answer could not be read")
        case "no_windows": L("Anthropic reported no limit windows")
        default: L("the network was unavailable")
        }
    }
}
