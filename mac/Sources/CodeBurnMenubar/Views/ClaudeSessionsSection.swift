import SwiftUI

// Claude › Plan: what each 5-hour session and each week cost at API prices,
// against how much of the limits it used. Every figure comes from
// `codeburn limits`; these views only lay it out. See
// docs/design/claude-session-usage.md.

private enum Columns {
    static let spent: CGFloat = 58
    static let fiveHour: CGFloat = 38
    static let week: CGFloat = 44
    static let mark: CGFloat = 14
    static let fullWeek: CGFloat = 62
}

@MainActor
private func money(_ usd: Double, unpriced: Bool = false, cents: Bool = false) -> String {
    ClaudeSessionFormat.money(usd, unpriced: unpriced, cents: cents, symbol: CurrencyState.shared.symbol, rate: CurrencyState.shared.rate)
}

@MainActor
private func estimatedMoney(_ usd: Double?, _ quality: ClaudeLimitsReport.Quality) -> String {
    ClaudeSessionFormat.estimatedMoney(usd, quality, symbol: CurrencyState.shared.symbol, rate: CurrencyState.shared.rate)
}

// MARK: - Spend lines under the bars

/// "$116 so far · 375M tokens · +8% of your week · full ≈ $190" under the
/// 5-hour bar.
struct ClaudeSessionSpendLine: View {
    let session: ClaudeLimitsReport.Session

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(text)
    }

    private var text: String {
        var parts = [
            L("%@ so far", money(session.spentUSD, unpriced: !session.unpricedModels.isEmpty)),
            L("%@ tokens", ClaudeSessionFormat.tokens(session.tokens.total)),
        ]
        if session.weekQuality.isKnown {
            parts.append(L("%@ of your week", ClaudeSessionFormat.percent(session.weekPct, session.weekQuality, signed: true)))
        }
        if let full = session.fullSessionUSD, session.fullSessionQuality.isKnown {
            parts.append(L("full %@", estimatedMoney(full, session.fullSessionQuality)))
        }
        return parts.joined(separator: " · ")
    }
}

/// "$118 so far · full week ≈ $1,470" under the 7-day bar.
struct ClaudeWeekSpendLine: View {
    let week: ClaudeLimitsReport.Week

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(text)
    }

    private var text: String {
        var parts = [L("%@ so far", money(week.spentUSD, unpriced: !week.unpricedModels.isEmpty))]
        if let full = week.fullWeekUSD, week.fullWeekQuality.isKnown {
            parts.append(L("full week %@", estimatedMoney(full, week.fullWeekQuality)))
        }
        return parts.joined(separator: " · ")
    }
}

/// The 5-hour row when no session is running.
struct ClaudeNoSessionRow: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(L("Current session (5h)"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        Text(L("No session running · the next one starts with your next message"))
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Summary, switch and lists

/// The summary line, the Sessions | Weeks switch and the chosen list.
struct ClaudeSessionsPlanSection: View {
    @Environment(AppStore.self) private var store
    let report: ClaudeLimitsReport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                if report.current.week?.ranOutAt != nil || report.current.session?.ranOut != nil || report.runsOutFirstAtSessionPct != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.brandAccent)
                }
                Text(ClaudeSessionFormat.summaryLine(report))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

            HStack {
                SegmentPills(
                    options: ClaudeSessionsListMode.allCases,
                    label: \.displayLabel,
                    selection: Binding(get: { store.claudeSessionsListMode }, set: { store.claudeSessionsListMode = $0 })
                )
                Spacer()
            }

            switch store.claudeSessionsListMode {
            case .sessions: ClaudeSessionsList(report: report)
            case .weeks: ClaudeWeeksList(weeks: report.weeks)
            }
        }
    }
}

/// Small pill switch in the style of the Trend Cost | Tokens toggle.
struct SegmentPills<Option: Hashable>: View {
    let options: [Option]
    let label: (Option) -> String
    @Binding var selection: Option

    init(options: [Option], label: KeyPath<Option, String>, selection: Binding<Option>) {
        self.options = options
        self.label = { $0[keyPath: label] }
        self._selection = selection
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button { selection = option } label: {
                    Text(label(option))
                        .font(.system(size: 10, weight: .medium))
                        .fixedSize()
                        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(selected ? AnyShapeStyle(Theme.brandAccent) : AnyShapeStyle(Color.secondary.opacity(0.10)))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

private struct ColumnHeader: View {
    let caption: String
    let columns: [(String, CGFloat)]

    var body: some View {
        HStack(spacing: 4) {
            Text(caption)
                .lineLimit(1)
            Spacer(minLength: 4)
            ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                Text(column.0)
                    .lineLimit(1)
                    .frame(width: column.1, alignment: .trailing)
            }
            Color.clear.frame(width: Columns.mark)
        }
        .font(.system(size: 8.5, weight: .semibold))
        .tracking(0.3)
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
    }
}

struct ClaudeSessionsList: View {
    let report: ClaudeLimitsReport
    @State private var expanded: String?
    @State private var showAll = false

    /// `expanded` opens one row from the start (layout tests).
    init(report: ClaudeLimitsReport, expanded: String? = nil) {
        self.report = report
        self._expanded = State(initialValue: expanded)
    }

    private static let collapsedCount = 8

    var body: some View {
        let sessions = report.sessions
        let shown = showAll ? sessions : Array(sessions.prefix(Self.collapsedCount))
        let resets = weekResets(in: sessions)

        VStack(alignment: .leading, spacing: 4) {
            ColumnHeader(
                caption: L("5-HOUR SESSIONS · API PRICES"),
                columns: [(L("Spent"), Columns.spent), (L("5h"), Columns.fiveHour), (L("Week"), Columns.week)]
            )
            if sessions.isEmpty {
                Text(L("No Claude sessions in the last seven days"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            }
            ForEach(shown) { session in
                if let reset = resets[session.id] {
                    WeekResetDivider(resetAt: reset)
                }
                ClaudeSessionRow(
                    session: session,
                    isOpen: expanded == session.id,
                    toggle: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            expanded = expanded == session.id ? nil : session.id
                        }
                    }
                )
            }
            if sessions.count > Self.collapsedCount, !showAll {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { showAll = true }
                } label: {
                    Text(L("Show all %lld ›", sessions.count))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.brandAccent)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
    }

    /// The weekly resets inside the list, keyed by the id of the row the
    /// divider sits above: the newest session that started before the reset
    /// (rows are newest first).
    private func weekResets(in sessions: [ClaudeLimitsReport.Session]) -> [String: Date] {
        var out: [String: Date] = [:]
        for start in report.weeks.map(\.start) where start <= report.generatedAt {
            guard let row = sessions.first(where: { $0.start < start }) else { continue }
            out[row.id] = start
        }
        return out
    }
}

private struct WeekResetDivider: View {
    let resetAt: Date

    var body: some View {
        HStack(spacing: 6) {
            Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 14, height: 0.5)
            Text(L("week reset · %@", ClaudeSessionFormat.weekdayClock(resetAt)))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
                .fixedSize()
            Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 0.5)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct ClaudeSessionRow: View {
    let session: ClaudeLimitsReport.Session
    let isOpen: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.quaternary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                    if session.running {
                        Circle().fill(Theme.brandAccent).frame(width: 5, height: 5)
                    }
                    Text(ClaudeSessionFormat.sessionRange(start: session.start, end: session.end, inferred: session.startInferred))
                        .font(.system(size: 10.5, weight: session.running ? .semibold : .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(money(session.spentUSD, unpriced: !session.unpricedModels.isEmpty))
                        .frame(width: Columns.spent, alignment: .trailing)
                    Text(ClaudeSessionFormat.percent(session.fiveHourPct, session.fiveHourQuality))
                        .frame(width: Columns.fiveHour, alignment: .trailing)
                    Text(ClaudeSessionFormat.percent(session.weekPct, session.weekQuality, signed: true))
                        .frame(width: Columns.week, alignment: .trailing)
                    Text(session.ranOut != nil ? ClaudeSessionFormat.ranOutMark : "")
                        .foregroundStyle(Theme.brandAccent)
                        .frame(width: Columns.mark, alignment: .trailing)
                }
                .font(.codeMono(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityText)
            .accessibilityHint(isOpen ? L("Hides session details") : L("Shows session details"))

            if isOpen {
                ClaudeSessionDetail(session: session)
                    .padding(.top, 6)
                    .padding(.leading, 12)
                    .padding(.bottom, 4)
                    .transition(.opacity)
            }
        }
    }

    private var accessibilityText: String {
        var parts = [
            ClaudeSessionFormat.sessionRange(start: session.start, end: session.end, inferred: session.startInferred),
            L("spent %@", money(session.spentUSD, unpriced: !session.unpricedModels.isEmpty)),
            L("5-hour used %1$@, %2$@", ClaudeSessionFormat.percent(session.fiveHourPct, session.fiveHourQuality), session.fiveHourQuality.spoken),
            L("Week used %1$@, %2$@", ClaudeSessionFormat.percent(session.weekPct, session.weekQuality, signed: true), session.weekQuality.spoken),
        ]
        if session.ranOut != nil { parts.append(L("a limit ran out")) }
        parts.append(isOpen ? L("Expanded") : L("Collapsed"))
        return parts.joined(separator: ", ")
    }
}

private struct ClaudeSessionDetail: View {
    let session: ClaudeLimitsReport.Session

    private static let chatRows = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                MiniStat(
                    label: L("Spent"),
                    value: money(session.spentUSD, unpriced: !session.unpricedModels.isEmpty, cents: true),
                    detail: L("%@ tokens", ClaudeSessionFormat.tokens(session.tokens.total))
                )
                MiniStat(
                    label: L("5-hour"),
                    value: ClaudeSessionFormat.percent(session.fiveHourPct, session.fiveHourQuality),
                    detail: session.fiveHourQuality.spoken
                )
                MiniStat(
                    label: L("Week"),
                    value: ClaudeSessionFormat.percent(session.weekPct, session.weekQuality, signed: true),
                    detail: weekDetail
                )
            }

            ForEach(notes, id: \.self) { note in
                Text(note)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !session.chats.isEmpty {
                Text(L("Chats, by share of this session's spend"))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(session.chats.prefix(Self.chatRows)) { chat in
                        chatRow(title: chat.title, spent: chat.spentUSD)
                    }
                    if session.chats.count > Self.chatRows {
                        let rest = session.chats.dropFirst(Self.chatRows)
                        chatRow(
                            title: L("%lld more", rest.count),
                            spent: rest.reduce(0) { $0 + $1.spentUSD },
                            dim: true
                        )
                    }
                }
            }
        }
    }

    private var weekDetail: String {
        if let from = session.weekFrom, let to = session.weekTo {
            return "\(Int(from.rounded()))% → \(Int(to.rounded()))%"
        }
        return session.weekQuality.spoken
    }

    private var notes: [String] {
        var out: [String] = []
        if let ranOut = session.ranOut {
            switch ranOut.limit {
            case .fiveHour:
                out.append(L("Ran out at %1$@ after %2$@", ClaudeSessionFormat.clock(ranOut.at), money(ranOut.spentUSD, cents: true)))
            case .sevenDay:
                out.append(L("Week ran out at %1$@ after %2$@ this session", ClaudeSessionFormat.clock(ranOut.at), money(ranOut.spentUSD, cents: true)))
                if let full = session.fullSessionUSD, session.fullSessionQuality.isKnown {
                    out.append(L("A full session would have cost %@", estimatedMoney(full, session.fullSessionQuality)))
                }
            }
        } else if let full = session.fullSessionUSD, session.fullSessionQuality.isKnown {
            out.append(L("A full session would have cost %@", estimatedMoney(full, session.fullSessionQuality)))
        }
        if let split = session.weekSplit {
            out.append(L(
                "The week reset at %1$@: %2$@ this week, %3$@ last week",
                ClaudeSessionFormat.clock(split.resetAt),
                ClaudeSessionFormat.percent(split.thisWeek, split.thisWeek == nil ? .unknown : .measured, signed: true),
                ClaudeSessionFormat.percent(split.lastWeek, split.lastWeek == nil ? .unknown : .measured, signed: true)
            ))
        }
        if session.outsideThisMac {
            out.append(L("Used outside this Mac: the 5-hour limit rose while this Mac spent almost nothing"))
        }
        if let gap = session.gap {
            out.append(L(
                "No limit readings %1$@–%2$@ · %3$@",
                ClaudeSessionFormat.clock(gap.from),
                ClaudeSessionFormat.clock(gap.to),
                ClaudeSessionFormat.gapReason(gap.reason)
            ))
        }
        if !session.unpricedModels.isEmpty {
            out.append(L("Spend is a lower bound: CodeBurn has no price for %@", session.unpricedModels.joined(separator: ", ")))
        }
        return out
    }

    private func chatRow(title: String, spent: Double, dim: Bool = false) -> some View {
        let share = session.spentUSD > 0 ? spent / session.spentUSD * 100 : 0
        return HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(dim ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(money(spent))
                .font(.codeMono(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text("\(Int(share.rounded()))%")
                .font(.codeMono(size: 9.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .frame(width: 30, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ClaudeWeeksList: View {
    let weeks: [ClaudeLimitsReport.Week]
    @State private var expanded: Date?

    init(weeks: [ClaudeLimitsReport.Week], expanded: Date? = nil) {
        self.weeks = weeks
        self._expanded = State(initialValue: expanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ColumnHeader(
                caption: L("WEEKS · API PRICES"),
                columns: [(L("Spent"), Columns.spent), (L("Used"), Columns.fiveHour), (L("Full week"), Columns.fullWeek)]
            )
            ForEach(weeks) { week in
                ClaudeWeekRow(
                    week: week,
                    isOpen: expanded == week.start,
                    toggle: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            expanded = expanded == week.start ? nil : week.start
                        }
                    }
                )
            }
        }
    }
}

private struct ClaudeWeekRow: View {
    let week: ClaudeLimitsReport.Week
    let isOpen: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.quaternary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                    Text(label)
                        .font(.system(size: 10.5, weight: week.running ? .semibold : .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(money(week.spentUSD, unpriced: !week.unpricedModels.isEmpty))
                        .frame(width: Columns.spent, alignment: .trailing)
                    Text(ClaudeSessionFormat.percent(week.usedPct, week.usedQuality))
                        .frame(width: Columns.fiveHour, alignment: .trailing)
                    Text(estimatedMoney(week.fullWeekUSD, week.fullWeekUSD == nil ? .unknown : week.fullWeekQuality))
                        .frame(width: Columns.fullWeek, alignment: .trailing)
                    Text(week.ranOutAt != nil ? ClaudeSessionFormat.ranOutMark : "")
                        .foregroundStyle(Theme.brandAccent)
                        .frame(width: Columns.mark, alignment: .trailing)
                }
                .font(.codeMono(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityText)

            if isOpen {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        MiniStat(
                            label: L("Spent"),
                            value: money(week.spentUSD, unpriced: !week.unpricedModels.isEmpty, cents: true),
                            detail: L("%@ tokens", ClaudeSessionFormat.tokens(week.tokens.total))
                        )
                        MiniStat(label: L("Used"), value: ClaudeSessionFormat.percent(week.usedPct, week.usedQuality), detail: week.usedQuality.spoken)
                        MiniStat(
                            label: L("Full week"),
                            value: estimatedMoney(week.fullWeekUSD, week.fullWeekUSD == nil ? .unknown : week.fullWeekQuality),
                            detail: week.fullWeekQuality.spoken
                        )
                    }
                    ForEach(notes, id: \.self) { note in
                        Text(note)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 6)
                .padding(.leading, 12)
                .padding(.bottom, 4)
                .transition(.opacity)
            }
        }
    }

    private var label: String {
        if week.running {
            // The weekday alone: with four columns, "since Wed 11:00" does
            // not fit 360pt in every language. The expanded row has the time.
            return L("This week · since %@", ClaudeSessionFormat.weekday(week.start))
        }
        let range = ClaudeSessionFormat.weekRange(start: week.start, end: week.end)
        switch week.endReason {
        case .moved: return L("%@ · reset moved", range)
        case .earlyReset: return L("%@ · reset early", range)
        default: return range
        }
    }

    private var notes: [String] {
        var out: [String] = []
        if week.running {
            out.append(L("This week · since %@", ClaudeSessionFormat.weekdayClock(week.start)))
        }
        if let ranOut = week.ranOutAt {
            out.append(L("Ran out %@", ClaudeSessionFormat.weekdayClock(ranOut)))
        }
        if week.endReason == .moved || week.endReason == .earlyReset {
            out.append(L("Cut short when Anthropic moved the weekly reset, so it has no full-week value"))
        }
        if week.startInferred {
            out.append(L("No readings at the start of this week; its dates are inferred"))
        }
        return out
    }

    private var accessibilityText: String {
        var parts = [
            label,
            L("spent %@", money(week.spentUSD, unpriced: !week.unpricedModels.isEmpty)),
            L("Week used %1$@, %2$@", ClaudeSessionFormat.percent(week.usedPct, week.usedQuality), week.usedQuality.spoken),
        ]
        if week.ranOutAt != nil { parts.append(L("a limit ran out")) }
        parts.append(isOpen ? L("Expanded") : L("Collapsed"))
        return parts.joined(separator: ", ")
    }
}

// MARK: - All tab

/// One row under the All tab's hero: the current Claude session at a glance.
/// Opens Claude › Plan.
struct ClaudeSessionAllTabRow: View {
    @Environment(AppStore.self) private var store
    let report: ClaudeLimitsReport

    var body: some View {
        Button {
            store.openClaudePlan()
        } label: {
            HStack(spacing: 6) {
                Text(report.current.session == nil ? L("Claude") : L("Claude session"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Text(ClaudeSessionFormat.allTabValue(report, symbol: CurrencyState.shared.symbol, rate: CurrencyState.shared.rate))
                    .font(.codeMono(size: 10.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("Claude session: %@", ClaudeSessionFormat.allTabValue(report, symbol: CurrencyState.shared.symbol, rate: CurrencyState.shared.rate)))
        .accessibilityHint(L("Opens the Claude plan"))
    }
}
