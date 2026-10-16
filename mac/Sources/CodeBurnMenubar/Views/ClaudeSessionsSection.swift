import SwiftUI

// Claude › Plan: what each 5-hour session and each week cost at API prices,
// against how much of the limits it used. Every figure comes from
// `codeburn limits`; these views only lay it out. See
// docs/design/claude-session-usage.md.

private enum Columns {
    static let spent: CGFloat = 40
    static let meter: CGFloat = 40
    static let fiveHour: CGFloat = 30
    static let week: CGFloat = 34
    static let weekSpent: CGFloat = 46
    static let weekStrip: CGFloat = 50
    static let used: CGFloat = 32
    static let fullWeek: CGFloat = 56
    /// The gap between a meter or strip and the figure before it.
    static let meterGap: CGFloat = 6
    /// Rows and their open detail bleed this far past the content edges, so
    /// their highlight has room around the text.
    static let bleed: CGFloat = 6
}

@MainActor
private func money(_ usd: Double, unpriced: Bool = false, cents: Bool = false) -> String {
    ClaudeSessionFormat.money(usd, unpriced: unpriced, cents: cents, symbol: CurrencyState.shared.symbol, rate: CurrencyState.shared.rate)
}

/// Upper case in CodeBurn's display language, not the Mac's region: a
/// Turkish-region Mac would otherwise print "API PRİCES".
private func caps(_ text: String) -> String {
    text.uppercased(with: L10n.activeLocale)
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

// MARK: - Section

/// A warning when a limit ran out or is about to, the Sessions | Weeks
/// switch, and the chosen list.
struct ClaudeSessionsPlanSection: View {
    @Environment(AppStore.self) private var store
    let report: ClaudeLimitsReport
    /// The 7-day bar's "on pace" projection, in percent.
    var weekPace: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let warning = ClaudeSessionFormat.warningLine(report) {
                ClaudeCallout(text: warning)
            }

            HStack(alignment: .center, spacing: 6) {
                title
                    .lineLimit(1)
                Spacer(minLength: 6)
                ClaudeSegmented(
                    options: ClaudeSessionsListMode.allCases,
                    label: \.displayLabel,
                    selection: Binding(get: { store.claudeSessionsListMode }, set: { store.claudeSessionsListMode = $0 })
                )
            }

            switch store.claudeSessionsListMode {
            case .sessions: ClaudeSessionsList(report: report)
            case .weeks: ClaudeWeeksList(report: report, weekPace: weekPace)
            }
        }
    }

    /// "This week · 32% used" or "Last 4 weeks · API prices".
    private var title: some View {
        let (head, tail): (String, String)
        switch store.claudeSessionsListMode {
        case .sessions:
            let week = report.current.week
            head = L("This week")
            tail = L("%@ used", ClaudeSessionFormat.percent(week?.usedPct, week?.usedQuality ?? .unknown))
        case .weeks:
            head = L("Last 4 weeks")
            tail = L("API prices")
        }
        return HStack(spacing: 0) {
            Text(head).font(.system(size: 11, weight: .semibold)).foregroundStyle(.primary)
            Text(" · " + tail).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }
        .monospacedDigit()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Shared pieces

/// A gray track with the chosen option raised: the Sessions | Weeks switch,
/// and in `mini` size the tabs of an open row.
struct ClaudeSegmented<Option: Hashable>: View {
    let options: [Option]
    let label: (Option) -> String
    @Binding var selection: Option
    var mini = false

    init(options: [Option], label: KeyPath<Option, String>, selection: Binding<Option>, mini: Bool = false) {
        self.options = options
        self.label = { $0[keyPath: label] }
        self._selection = selection
        self.mini = mini
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button { selection = option } label: {
                    Text(label(option))
                        .font(.system(size: mini ? 9.5 : 10, weight: .semibold))
                        .fixedSize()
                        .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .padding(.horizontal, mini ? 7 : 9)
                        .padding(.vertical, mini ? 1.5 : 2.5)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(selected ? Color.primary.opacity(0.14) : .clear)
                                .shadow(color: .black.opacity(selected ? 0.25 : 0), radius: 1, y: 0.5)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
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

/// A limit that ran out, or something that makes a figure less certain.
private struct ClaudeCallout: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let scheme: QuotaWarningPalette.Scheme = colorScheme == .dark ? .dark : .light
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 8, weight: .bold))
            Text(text)
                .font(.system(size: 9.5, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(color(QuotaWarningPalette.foreground(.critical, scheme)))
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(color(QuotaWarningPalette.tint(.critical, scheme)).opacity(QuotaWarningPalette.pillOpacity))
        )
        .accessibilityElement(children: .combine)
    }

    private func color(_ rgb: QuotaWarningPalette.RGB) -> Color {
        Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

/// An informational line in an open row.
private struct ClaudeNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Diagonal stripes: a full session's width on the week strip, and the hours
/// or days still ahead on a chart.
private struct Hatch: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 5
            }
            context.stroke(path, with: .color(.primary.opacity(0.13)), lineWidth: 1.5)
        }
        .accessibilityHidden(true)
    }
}

/// A thin track filled to `percent`.
private struct Meter: View {
    let percent: Double?
    var hot = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                if let percent {
                    Capsule()
                        .fill(hot ? AnyShapeStyle(Theme.brandAccentLight) : AnyShapeStyle(Color.secondary))
                        .frame(width: geo.size.width * min(max(percent, 0), 100) / 100)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// A row with its share drawn as a bar behind it: chats, models.
private struct ShareRow: View {
    let title: String
    var detail: String? = nil
    let amount: String
    /// 0...1.
    let share: Double
    var dim = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(dim ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if let detail {
                Text(detail)
                    .font(.codeMono(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(amount)
                .font(.codeMono(size: 9.5, weight: .semibold))
                .foregroundStyle(dim ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .frame(minWidth: 34, alignment: .trailing)
            Text("\(Int((share * 100).rounded()))%")
                .font(.codeMono(size: 9.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 28, alignment: .trailing)
        }
        .monospacedDigit()
        .padding(.horizontal, Columns.bleed)
        .padding(.vertical, 3)
        .background(alignment: .leading) {
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 4)
                    .fill(dim ? Color.primary.opacity(0.05) : Theme.brandAccent.opacity(0.16))
                    .frame(width: geo.size.width * min(max(share, 0), 1))
            }
        }
        .padding(.horizontal, -Columns.bleed)
        .accessibilityElement(children: .combine)
    }
}

private struct ColumnHeader: View {
    let caption: String
    let columns: [(String, CGFloat)]

    var body: some View {
        HStack(spacing: 4) {
            Text(caps(caption))
                .lineLimit(1)
            Spacer(minLength: 4)
            ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                Text(caps(column.0))
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: column.1, alignment: .trailing)
            }
        }
        .font(.system(size: 8.5, weight: .semibold))
        .tracking(0.3)
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
    }
}

/// The fill behind a row: open rows join the detail under them.
private func rowShape(open: Bool) -> UnevenRoundedRectangle {
    UnevenRoundedRectangle(
        topLeadingRadius: 6,
        bottomLeadingRadius: open ? 0 : 6,
        bottomTrailingRadius: open ? 0 : 6,
        topTrailingRadius: 6
    )
}

private let detailShape = UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6)

// MARK: - Chart

/// Bars for the spend in each slice and a line for the limit's percent:
/// the hours of a session, the days of a week.
private struct ClaudeSliceChart: View {
    struct Slot {
        /// Nil for a slice still ahead.
        let slice: ClaudeLimitsReport.Slice?
        /// Under the bar in `.perSlot` axes.
        var label = ""
        let tooltip: String
    }

    enum Axis {
        case ends(start: String, now: String?, end: String)
        case perSlot
    }

    let slots: [Slot]
    let axis: Axis
    /// 0...1 across the chart, for a window still running.
    let nowFraction: Double?
    let spendLegend: String
    let lineLegend: String

    @State private var hovered: Int?

    private static let height: CGFloat = 48
    private static let labelHeight: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ZStack(alignment: .topLeading) {
                bars
                line
                if let nowFraction {
                    GeometryReader { geo in
                        Path { p in
                            let x = geo.size.width * nowFraction
                            p.move(to: CGPoint(x: x, y: 0))
                            p.addLine(to: CGPoint(x: x, y: geo.size.height))
                        }
                        .stroke(Color.primary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    }
                    .accessibilityHidden(true)
                }
            }
            .frame(height: Self.height)

            axisLabels
                .font(.codeMono(size: 8.5, weight: .medium))
                .foregroundStyle(.tertiary)

            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.2)).frame(width: 8, height: 6)
                    Text(spendLegend)
                }
                HStack(spacing: 4) {
                    Capsule().fill(Theme.brandAccentLight).frame(width: 8, height: 2)
                    Text(lineLegend)
                }
                Spacer(minLength: 4)
                if let hovered, slots.indices.contains(hovered) {
                    Text(slots[hovered].tooltip)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.tertiary)
            .monospacedDigit()
        }
    }

    private var maxSpend: Double {
        max(slots.compactMap { $0.slice?.spentUSD }.max() ?? 0, 0.01)
    }

    private var bars: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(slots.enumerated()), id: \.offset) { index, slot in
                Group {
                    if let slice = slot.slice {
                        let barHeight = max(3, (Self.height - Self.labelHeight) * slice.spentUSD / maxSpend)
                        VStack(spacing: 1) {
                            Spacer(minLength: 0)
                            Text(money(slice.spentUSD))
                                .font(.codeMono(size: 8.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                            UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2)
                                .fill(fill(index: index))
                                .frame(height: barHeight)
                        }
                    } else {
                        Hatch()
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside { hovered = index } else if hovered == index { hovered = nil }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(slot.tooltip)
            }
        }
    }

    private func fill(index: Int) -> Color {
        let current = nowFraction != nil && index == lastFilledIndex
        if hovered == index { return current ? Theme.brandAccentLight.opacity(0.75) : Color.primary.opacity(0.28) }
        return current ? Theme.brandAccentLight.opacity(0.45) : Color.primary.opacity(0.13)
    }

    private var lastFilledIndex: Int? {
        slots.lastIndex { $0.slice != nil }
    }

    /// The percent at the end of each slice that has a reading, from 0 at the
    /// start. Segments across slices without a reading are dashed.
    private var line: some View {
        GeometryReader { geo in
            let count = CGFloat(max(slots.count, 1))
            let points: [(index: Int, point: CGPoint)] = [(-1, CGPoint(x: 0, y: geo.size.height))]
                + slots.enumerated().compactMap { index, slot in
                    guard let pct = slot.slice?.pct else { return nil }
                    let x = geo.size.width * CGFloat(index + 1) / count
                    let y = geo.size.height * (1 - CGFloat(min(max(pct, 0), 100)) / 100)
                    return (index, CGPoint(x: x, y: y))
                }
            let pairs = Array(zip(points, points.dropFirst()))
            ZStack {
                Path { p in
                    for (a, b) in pairs where b.index == a.index + 1 {
                        p.move(to: a.point)
                        p.addLine(to: b.point)
                    }
                }
                .stroke(Theme.brandAccentLight, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                Path { p in
                    for (a, b) in pairs where b.index != a.index + 1 {
                        p.move(to: a.point)
                        p.addLine(to: b.point)
                    }
                }
                .stroke(Theme.brandAccentLight.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, dash: [3, 2]))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var axisLabels: some View {
        switch axis {
        case .ends(let start, let now, let end):
            HStack(spacing: 4) {
                Text(start)
                Spacer(minLength: 2)
                if let now {
                    Text(now).foregroundStyle(Theme.brandAccentLight)
                    Spacer(minLength: 2)
                }
                Text(end)
            }
        case .perSlot:
            HStack(spacing: 3) {
                ForEach(Array(slots.enumerated()), id: \.offset) { _, slot in
                    Text(slot.label)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

/// The figures of a chart tooltip such as "18:10–19:10 · $9 · 5h 6% → 15%":
/// the slice's spend, the last percent known before it (0 at the window's
/// start) and its own percent.
@MainActor
private func sliceFigures(_ slice: ClaudeLimitsReport.Slice, previous: Double?) -> (String, String, String) {
    (
        money(slice.spentUSD),
        ClaudeSessionFormat.percent(previous ?? 0, .measured),
        ClaudeSessionFormat.percent(slice.pct, slice.pct == nil ? .unknown : .measured)
    )
}

// MARK: - Sessions

enum ClaudeSessionDetailTab: String, CaseIterable, Hashable, Sendable {
    case chats, hours, models

    var displayLabel: String {
        switch self {
        case .chats: L("Chats")
        case .hours: L("Hours")
        case .models: L("Models")
        }
    }
}

/// The week strip, the sessions of the last seven days grouped by day, and
/// a divider at each weekly reset.
struct ClaudeSessionsList: View {
    let report: ClaudeLimitsReport
    @State private var expanded: String?
    @State private var showAll = false
    /// A session pointed at on the strip or in the list; the other lights up.
    @State private var highlighted: String?
    /// One tab for every open row, so switching to Hours compares sessions.
    @State private var tab: ClaudeSessionDetailTab

    /// `expanded` and `tab` open one row from the start (layout tests).
    init(report: ClaudeLimitsReport, expanded: String? = nil, tab: ClaudeSessionDetailTab = .chats) {
        self.report = report
        self._expanded = State(initialValue: expanded)
        self._tab = State(initialValue: tab)
    }

    private static let collapsedCount = 8

    var body: some View {
        let sessions = report.sessions
        let shown = showAll ? sessions : Array(sessions.prefix(Self.collapsedCount))
        let resets = weekResets(in: sessions)

        VStack(alignment: .leading, spacing: 0) {
            if report.current.week != nil {
                ClaudeWeekStrip(
                    blocks: stripBlocks,
                    fullSessionShare: report.fullSessionWeekShare,
                    highlighted: $highlighted,
                    select: { id in
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            if !shown.contains(where: { $0.id == id }) { showAll = true }
                            expanded = id
                        }
                    }
                )
            }
            HStack(spacing: 4) {
                if report.current.week != nil { Text(L("1 block = 1 session")) }
                Spacer(minLength: 4)
                Text(legend).foregroundStyle(.secondary)
            }
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.tertiary)
            .monospacedDigit()
            .lineLimit(1)
            .padding(.top, 5)

            ColumnHeader(
                caption: L("API prices"),
                columns: [
                    (L("Spent"), Columns.spent),
                    (L("5-hour"), Columns.meterGap + Columns.meter + 4 + Columns.fiveHour),
                    (L("Week"), Columns.week),
                ]
            )
            .padding(.top, 8)

            if sessions.isEmpty {
                Text(L("No Claude sessions in the last seven days"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            }

            ForEach(dayGroups(shown), id: \.day) { group in
                DayHeader(day: group.day, total: group.sessions.reduce(0) { $0 + $1.spentUSD }, unpriced: group.sessions.contains { !$0.unpricedModels.isEmpty })
                    .padding(.top, 8)
                    .padding(.bottom, 2)
                ForEach(group.sessions) { session in
                    if let reset = resets[session.id] {
                        WeekResetDivider(resetAt: reset)
                    }
                    ClaudeSessionRow(
                        session: session,
                        isOpen: expanded == session.id,
                        isHighlighted: highlighted == session.id,
                        hover: { inside in
                            if inside { highlighted = session.id } else if highlighted == session.id { highlighted = nil }
                        },
                        toggle: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                expanded = expanded == session.id ? nil : session.id
                            }
                        },
                        tab: $tab
                    )
                }
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
                .padding(.top, 6)
            }
        }
    }

    /// "full session ≈ 8% · ≈ 8 left", or why there is no such figure yet.
    private var legend: String {
        guard let share = report.fullSessionWeekShare else { return L("Not enough sessions yet to measure") }
        return L("full session ≈ %1$lld%% · ≈ %2$lld left", Int(share.rounded()), report.sessionsLeft ?? 0)
    }

    /// The current week's sessions, oldest first, from the CLI; an older CLI
    /// does not send them, so fall back to the listed sessions in the week.
    private var stripBlocks: [ClaudeWeekStrip.Block] {
        guard let week = report.current.week else { return [] }
        let sessions: [ClaudeLimitsReport.WeekSession] = week.sessions ?? report.sessions
            .filter { $0.start >= week.start }
            .reversed()
            .map { .init(id: $0.id, start: $0.start, end: $0.end, running: $0.running, spentUSD: $0.spentUSD, weekPct: $0.weekPct, weekQuality: $0.weekQuality) }
        return sessions.compactMap { session in
            guard let pct = session.weekPct, session.weekQuality.isKnown else { return nil }
            let range = ClaudeSessionFormat.sessionRange(start: session.start, end: session.end, inferred: false)
            return .init(
                id: session.id,
                percent: pct,
                running: session.running,
                label: L("Session %1$@, %2$@ of the week", range, ClaudeSessionFormat.percent(pct, session.weekQuality, signed: true))
            )
        }
    }

    private struct DayGroup {
        let day: Date
        let sessions: [ClaudeLimitsReport.Session]
    }

    /// Sessions by the local day they started, newest first like the list.
    private func dayGroups(_ sessions: [ClaudeLimitsReport.Session]) -> [DayGroup] {
        let calendar = Calendar.current
        var groups: [DayGroup] = []
        for session in sessions {
            let day = calendar.startOfDay(for: session.start)
            if let last = groups.last, last.day == day {
                groups[groups.count - 1] = DayGroup(day: day, sessions: last.sessions + [session])
            } else {
                groups.append(DayGroup(day: day, sessions: [session]))
            }
        }
        return groups
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

/// The current week as blocks, one per session, each as wide as its share of
/// the week; a striped block shows what a full session would take.
private struct ClaudeWeekStrip: View {
    struct Block: Identifiable {
        let id: String
        let percent: Double
        let running: Bool
        let label: String
    }

    let blocks: [Block]
    let fullSessionShare: Double?
    @Binding var highlighted: String?
    let select: (String) -> Void

    private static let gap: CGFloat = 1.5

    var body: some View {
        GeometryReader { geo in
            let gaps = CGFloat(blocks.count) * Self.gap
            let perPoint = max(0, geo.size.width - gaps) / 100
            HStack(spacing: Self.gap) {
                ForEach(blocks) { block in
                    Rectangle()
                        .fill(block.running ? Theme.brandAccentLight : Theme.brandAccent)
                        .opacity(highlighted == nil || highlighted == block.id ? 1 : 0.35)
                        .brightness(highlighted == block.id ? 0.1 : 0)
                        .frame(width: max(2, block.percent * perPoint))
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside { highlighted = block.id } else if highlighted == block.id { highlighted = nil }
                        }
                        .onTapGesture { select(block.id) }
                        .accessibilityElement()
                        .accessibilityLabel(block.label)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { select(block.id) }
                }
                if let share = fullSessionShare, share > 0 {
                    Hatch()
                        .frame(width: share * perPoint)
                        .help(L("About one full 5-hour session"))
                }
                Spacer(minLength: 0)
            }
            .frame(width: geo.size.width, alignment: .leading)
        }
        .frame(height: 14)
        .background(Color.primary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .animation(.easeOut(duration: 0.12), value: highlighted)
    }
}

/// "TODAY · FRI   $32".
private struct DayHeader: View {
    let day: Date
    let total: Double
    let unpriced: Bool

    var body: some View {
        HStack {
            Text(caps(label))
                .tracking(0.4)
            Spacer(minLength: 4)
            Text(money(total, unpriced: unpriced))
                .font(.codeMono(size: 9, weight: .semibold))
        }
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(.tertiary)
        .accessibilityElement(children: .combine)
    }

    private var label: String {
        let calendar = Calendar.current
        let weekday = ClaudeSessionFormat.weekday(day)
        if calendar.isDateInToday(day) { return "\(L("Today")) · \(weekday)" }
        if calendar.isDateInYesterday(day) { return "\(L("Yesterday")) · \(weekday)" }
        return weekday
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
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct ClaudeSessionRow: View {
    let session: ClaudeLimitsReport.Session
    let isOpen: Bool
    let isHighlighted: Bool
    let hover: (Bool) -> Void
    let toggle: () -> Void
    @Binding var tab: ClaudeSessionDetailTab

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(session.running ? Theme.brandAccentLight : Theme.brandAccent)
                        .frame(width: 8, height: 8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Theme.brandAccentLight.opacity(session.running ? 0.3 : 0), lineWidth: 2)
                                .padding(-2)
                        )
                        .padding(.trailing, 3)
                    HStack(spacing: 0) {
                        Text(range)
                            .font(.system(size: 10.5, weight: session.running ? .semibold : .medium))
                            .foregroundStyle(.primary)
                        if session.running {
                            Text(" · " + L("now"))
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(Theme.brandAccentLight)
                        }
                        if session.ranOut != nil {
                            Text(" " + ClaudeSessionFormat.ranOutMark)
                                .foregroundStyle(Theme.brandAccent)
                        }
                    }
                    .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(money(session.spentUSD, unpriced: !session.unpricedModels.isEmpty))
                        .foregroundStyle(.primary)
                        .frame(width: Columns.spent, alignment: .trailing)
                    Meter(percent: session.fiveHourQuality.isKnown ? session.fiveHourPct : nil, hot: (session.fiveHourPct ?? 0) >= 90)
                        .frame(width: Columns.meter, height: 4)
                        .padding(.leading, Columns.meterGap)
                    Text(ClaudeSessionFormat.percent(session.fiveHourPct, session.fiveHourQuality))
                        .frame(width: Columns.fiveHour, alignment: .trailing)
                    Text(ClaudeSessionFormat.percent(session.weekPct, session.weekQuality, signed: true))
                        .foregroundStyle(Theme.brandAccentLight)
                        .frame(width: Columns.week, alignment: .trailing)
                }
                .font(.codeMono(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, Columns.bleed)
                .padding(.vertical, 4)
                .background(rowShape(open: isOpen).fill(rowFill))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover(perform: hover)
            .accessibilityLabel(accessibilityText)
            .accessibilityHint(isOpen ? L("Hides session details") : L("Shows session details"))

            if isOpen {
                ClaudeSessionDetail(session: session, tab: $tab)
                    .padding(.leading, 23)
                    .padding(.trailing, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 9)
                    .background(detailShape.fill(session.running ? Theme.brandAccent.opacity(0.06) : Color.primary.opacity(0.035)))
                    .padding(.bottom, 4)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, -Columns.bleed)
    }

    private var range: String {
        let clock = "\(ClaudeSessionFormat.clock(session.start))–\(ClaudeSessionFormat.clock(session.end))"
        return session.startInferred ? "≈ \(clock)" : clock
    }

    private var rowFill: Color {
        if session.running { return Theme.brandAccent.opacity(isOpen ? 0.16 : 0.13) }
        if isOpen { return Color.primary.opacity(0.06) }
        return Color.primary.opacity(isHighlighted ? 0.05 : 0)
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
    @Binding var tab: ClaudeSessionDetailTab

    private static let chatRows = 3
    private static let modelRows = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    meta
                    Spacer(minLength: 4)
                    tabs
                }
                VStack(alignment: .leading, spacing: 6) {
                    tabs
                    meta
                }
            }

            switch shownTab {
            case .chats: chats
            case .hours: hours
            case .models: models
            }

            ForEach(warnings, id: \.self) { ClaudeCallout(text: $0) }
            ForEach(notes, id: \.self) { ClaudeNote(text: $0) }
        }
    }

    /// Hours and Models need a CLI that sends them.
    private var availableTabs: [ClaudeSessionDetailTab] {
        ClaudeSessionDetailTab.allCases.filter {
            switch $0 {
            case .chats: true
            case .hours: session.hours?.isEmpty == false
            case .models: session.models?.isEmpty == false
            }
        }
    }

    private var shownTab: ClaudeSessionDetailTab {
        availableTabs.contains(tab) ? tab : .chats
    }

    @ViewBuilder
    private var tabs: some View {
        if availableTabs.count > 1 {
            ClaudeSegmented(
                options: availableTabs,
                label: \.displayLabel,
                selection: Binding(get: { shownTab }, set: { tab = $0 }),
                mini: true
            )
        }
    }

    private var meta: some View {
        HStack(spacing: 9) {
            Text(L("%@ tokens", ClaudeSessionFormat.tokens(session.tokens.total)))
            if let full = session.fullSessionUSD, session.fullSessionQuality.isKnown {
                Text(L("full session %@", estimatedMoney(full, session.fullSessionQuality)))
            }
        }
        .font(.system(size: 9.5, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .fixedSize()
    }

    @ViewBuilder
    private var chats: some View {
        if session.chats.isEmpty {
            ClaudeNote(text: L("No chats on this Mac in this session"))
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(session.chats.prefix(Self.chatRows)) { chat in
                    ShareRow(title: chat.title, amount: money(chat.spentUSD), share: share(chat.spentUSD))
                }
                if session.chats.count > Self.chatRows {
                    let rest = session.chats.dropFirst(Self.chatRows)
                    let spent = rest.reduce(0) { $0 + $1.spentUSD }
                    ShareRow(title: L("%lld more", rest.count), amount: money(spent), share: share(spent), dim: true)
                }
            }
        }
    }

    @ViewBuilder
    private var hours: some View {
        let hours = session.hours ?? []
        // A running session also shows the hours still ahead.
        let count = session.running
            ? max(hours.count, min(5, Int((session.end.timeIntervalSince(session.start) / 3600).rounded(.up))))
            : max(hours.count, 1)
        let slots = (0..<count).map { index -> ClaudeSliceChart.Slot in
            guard index < hours.count else { return .init(slice: nil, tooltip: L("Still ahead")) }
            let slice = hours[index]
            let previous = hours[..<index].last(where: { $0.pct != nil })?.pct
            let label = "\(ClaudeSessionFormat.clock(slice.start))–\(ClaudeSessionFormat.clock(slice.end))"
            let (spent, from, to) = sliceFigures(slice, previous: previous)
            return .init(slice: slice, tooltip: L("%1$@ · %2$@ · 5h %3$@ → %4$@", label, spent, from, to))
        }
        ClaudeSliceChart(
            slots: slots,
            axis: .ends(
                start: ClaudeSessionFormat.clock(session.start),
                now: session.running ? L("now %@", ClaudeSessionFormat.clock(Date())) : nil,
                end: ClaudeSessionFormat.clock(session.end)
            ),
            nowFraction: session.running ? fraction(of: Date(), from: session.start, to: session.end) : nil,
            spendLegend: L("spend per hour"),
            lineLegend: L("5-hour used → %@", ClaudeSessionFormat.percent(session.fiveHourPct, session.fiveHourQuality))
        )
    }

    @ViewBuilder
    private var models: some View {
        let models = session.models ?? []
        VStack(alignment: .leading, spacing: 2) {
            ForEach(models.prefix(Self.modelRows)) { model in
                ShareRow(title: model.model, detail: ClaudeSessionFormat.tokens(model.tokens), amount: money(model.spentUSD), share: share(model.spentUSD))
            }
            if models.count > Self.modelRows {
                let rest = models.dropFirst(Self.modelRows)
                let spent = rest.reduce(0) { $0 + $1.spentUSD }
                ShareRow(title: L("%lld more", rest.count), amount: money(spent), share: share(spent), dim: true)
            }
        }
    }

    private func share(_ spent: Double) -> Double {
        session.spentUSD > 0 ? spent / session.spentUSD : 0
    }

    private var warnings: [String] {
        var out: [String] = []
        if let ranOut = session.ranOut {
            switch ranOut.limit {
            case .fiveHour:
                out.append(L("Ran out at %1$@ after %2$@", ClaudeSessionFormat.clock(ranOut.at), money(ranOut.spentUSD, cents: true)))
            case .sevenDay:
                out.append(L("Week ran out at %1$@ after %2$@ this session", ClaudeSessionFormat.clock(ranOut.at), money(ranOut.spentUSD, cents: true)))
            }
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

    private var notes: [String] {
        guard let split = session.weekSplit else { return [] }
        return [L(
            "The week reset at %1$@: %2$@ this week, %3$@ last week",
            ClaudeSessionFormat.clock(split.resetAt),
            ClaudeSessionFormat.percent(split.thisWeek, split.thisWeek == nil ? .unknown : .measured, signed: true),
            ClaudeSessionFormat.percent(split.lastWeek, split.lastWeek == nil ? .unknown : .measured, signed: true)
        )]
    }
}

private func fraction(of date: Date, from start: Date, to end: Date) -> Double {
    let span = end.timeIntervalSince(start)
    guard span > 0 else { return 0 }
    return min(max(date.timeIntervalSince(start) / span, 0), 1)
}

// MARK: - Weeks

enum ClaudeWeekDetailTab: String, CaseIterable, Hashable, Sendable {
    case days, sessions, models

    var displayLabel: String {
        switch self {
        case .days: L("Days")
        case .sessions: L("Sessions")
        case .models: L("Models")
        }
    }
}

/// This week against the last at the same point, and the current week with
/// the three before it.
struct ClaudeWeeksList: View {
    let report: ClaudeLimitsReport
    var weekPace: Double? = nil
    @State private var expanded: Date?
    @State private var tab: ClaudeWeekDetailTab

    init(report: ClaudeLimitsReport, weekPace: Double? = nil, expanded: Date? = nil, tab: ClaudeWeekDetailTab = .days) {
        self.report = report
        self.weekPace = weekPace
        self._expanded = State(initialValue: expanded)
        self._tab = State(initialValue: tab)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let week = report.current.week, let previous = week.previousAtSamePoint {
                ClaudeWeekComparison(week: week, previous: previous, now: report.generatedAt)
                    .padding(.bottom, 5)
            }
            if averageText != nil || weekPace != nil {
                HStack(spacing: 4) {
                    if let averageText { Text(averageText) }
                    Spacer(minLength: 4)
                    if let weekPace {
                        Text(L("this week on pace for %@", "\(Int(weekPace.rounded()))%"))
                    }
                }
                .font(.system(size: 9.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            ColumnHeader(
                caption: "",
                columns: [
                    (L("Spent"), Columns.weekSpent),
                    (L("Used"), Columns.meterGap + Columns.weekStrip + 4 + Columns.used),
                    (L("Full week"), Columns.fullWeek),
                ]
            )
            .padding(.top, 8)
            .padding(.bottom, 2)

            ForEach(report.weeks) { week in
                ClaudeWeekRow(
                    week: week,
                    isOpen: expanded == week.start,
                    toggle: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            expanded = expanded == week.start ? nil : week.start
                        }
                    },
                    tab: $tab
                )
            }
        }
    }

    /// "avg full week ≈ $1,386" from the past weeks that have a full-week value.
    private var averageText: String? {
        guard let average = report.fullWeekAverage, let usd = average.usd, average.basis > 0 else { return nil }
        return L("avg full week %@", estimatedMoney(usd, .estimated))
    }
}

/// "THIS WEEK VS LAST, SAME POINT (FRI 01:26)  −22%" over two bars.
private struct ClaudeWeekComparison: View {
    let week: ClaudeLimitsReport.Week
    let previous: ClaudeLimitsReport.SamePoint
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(caps(L("This week vs last, same point (%@)", ClaudeSessionFormat.weekdayClock(now))))
                    .tracking(0.3)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                if let change {
                    Text(change).foregroundStyle(Theme.brandAccentGlow)
                }
            }
            .font(.system(size: 9, weight: .semibold))
            line(L("This week"), percent: week.usedPct, quality: week.usedQuality, spent: week.spentUSD, unpriced: !week.unpricedModels.isEmpty, current: true)
            line(L("Last week"), percent: previous.usedPct, quality: previous.usedQuality, spent: previous.spentUSD, unpriced: false, current: false)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07)))
        .accessibilityElement(children: .combine)
    }

    /// The change in spend, "−22%"; nil when last week had spent nothing yet.
    private var change: String? {
        guard previous.spentUSD >= 1 else { return nil }
        let pct = Int(((week.spentUSD - previous.spentUSD) / previous.spentUSD * 100).rounded())
        return pct < 0 ? "−\(-pct)%" : "+\(pct)%"
    }

    private func line(_ label: String, percent: Double?, quality: ClaudeLimitsReport.Quality, spent: Double, unpriced: Bool, current: Bool) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.06))
                    if let percent, quality.isKnown {
                        Capsule()
                            .fill(current ? AnyShapeStyle(Theme.brandAccentLight) : AnyShapeStyle(Color.primary.opacity(0.3)))
                            .frame(width: geo.size.width * min(max(percent, 0), 100) / 100)
                    }
                }
            }
            .frame(height: 5)
            Text("\(money(spent, unpriced: unpriced)) · \(ClaudeSessionFormat.percent(percent, quality))")
                .font(.codeMono(size: 9.5, weight: .semibold))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .fixedSize()
        }
    }
}

private struct ClaudeWeekRow: View {
    @Environment(AppStore.self) private var store
    let week: ClaudeLimitsReport.Week
    let isOpen: Bool
    let toggle: () -> Void
    @Binding var tab: ClaudeWeekDetailTab
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 4) {
                    HStack(spacing: 5) {
                        Text(label)
                            .font(.system(size: 10.5, weight: week.running ? .semibold : .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if week.ranOutAt != nil {
                            Text(caps(L("Ran out")))
                                .font(.system(size: 8.5, weight: .bold))
                                .tracking(0.2)
                                .foregroundStyle(Theme.brandAccentLight)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 3).fill(Theme.brandAccent.opacity(0.18)))
                                .fixedSize()
                        }
                    }
                    Spacer(minLength: 4)
                    Text(money(week.spentUSD, unpriced: !week.unpricedModels.isEmpty))
                        .foregroundStyle(.primary)
                        .frame(width: Columns.weekSpent, alignment: .trailing)
                    ClaudeWeekMiniStrip(week: week)
                        .frame(width: Columns.weekStrip, height: 6)
                        .padding(.leading, Columns.meterGap)
                    Text(ClaudeSessionFormat.percent(week.usedPct, week.usedQuality))
                        .frame(width: Columns.used, alignment: .trailing)
                    Text(estimatedMoney(week.fullWeekUSD, week.fullWeekUSD == nil ? .unknown : week.fullWeekQuality))
                        .lineLimit(1)
                        .frame(width: Columns.fullWeek, alignment: .trailing)
                }
                .font(.codeMono(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, Columns.bleed)
                .padding(.vertical, 4)
                .background(rowShape(open: isOpen).fill(rowFill))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityLabel(accessibilityText)

            if isOpen {
                ClaudeWeekDetail(week: week, tab: $tab, showSessions: { store.claudeSessionsListMode = .sessions })
                    .padding(.leading, 12)
                    .padding(.trailing, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 9)
                    .background(detailShape.fill(week.running ? Theme.brandAccent.opacity(0.06) : Color.primary.opacity(0.035)))
                    .padding(.bottom, 4)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, -Columns.bleed)
    }

    private var rowFill: Color {
        if week.running { return Theme.brandAccent.opacity(isOpen ? 0.16 : 0.13) }
        if isOpen { return Color.primary.opacity(0.06) }
        return Color.primary.opacity(hovering ? 0.05 : 0)
    }

    private var label: String {
        if week.running {
            // The weekday alone: with four columns, "since Wed 11:00" does
            // not fit 360pt in every language. The expanded row has the time.
            return L("This week · since %@", ClaudeSessionFormat.weekday(week.start))
        }
        return ClaudeSessionFormat.compactWeekRange(start: week.start, end: week.end)
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

/// A week's sessions as blocks of its used share; a plain bar when the CLI
/// sends no sessions.
private struct ClaudeWeekMiniStrip: View {
    let week: ClaudeLimitsReport.Week

    var body: some View {
        GeometryReader { geo in
            let blocks = (week.sessions ?? []).compactMap { $0.weekQuality.isKnown ? $0.weekPct : nil }
            HStack(spacing: 1) {
                if blocks.isEmpty {
                    if let used = week.usedPct, week.usedQuality.isKnown {
                        Rectangle().fill(fill).frame(width: geo.size.width * min(used, 100) / 100)
                    }
                } else {
                    let perPoint = max(0, geo.size.width - CGFloat(blocks.count)) / 100
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, pct in
                        Rectangle().fill(fill).frame(width: max(1, pct * perPoint))
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .background(Color.primary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .accessibilityHidden(true)
    }

    private var fill: Color {
        if week.running { return Theme.brandAccent }
        if week.ranOutAt != nil { return Theme.brandAccentDeep }
        return Color.primary.opacity(0.38)
    }
}

private struct ClaudeWeekDetail: View {
    let week: ClaudeLimitsReport.Week
    @Binding var tab: ClaudeWeekDetailTab
    let showSessions: () -> Void

    private static let sessionRows = 4
    private static let modelRows = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    meta
                    Spacer(minLength: 4)
                    tabs
                }
                VStack(alignment: .leading, spacing: 6) {
                    tabs
                    meta
                }
            }

            switch shownTab {
            case .days: days
            case .sessions: sessions
            case .models: models
            case nil: EmptyView()
            }

            ForEach(warnings, id: \.self) { ClaudeCallout(text: $0) }
            ForEach(notes, id: \.self) { ClaudeNote(text: $0) }
        }
    }

    private var availableTabs: [ClaudeWeekDetailTab] {
        ClaudeWeekDetailTab.allCases.filter {
            switch $0 {
            case .days: week.days?.isEmpty == false
            case .sessions: week.sessions?.isEmpty == false
            case .models: week.models?.isEmpty == false
            }
        }
    }

    private var shownTab: ClaudeWeekDetailTab? {
        availableTabs.contains(tab) ? tab : availableTabs.first
    }

    @ViewBuilder
    private var tabs: some View {
        if availableTabs.count > 1 {
            ClaudeSegmented(
                options: availableTabs,
                label: \.displayLabel,
                selection: Binding(get: { shownTab ?? tab }, set: { tab = $0 }),
                mini: true
            )
        }
    }

    private var meta: some View {
        HStack(spacing: 9) {
            Text(L("%@ tokens", ClaudeSessionFormat.tokens(week.tokens.total)))
            if let sessions = week.sessions {
                Text(sessions.count == 1 ? L("1 session") : L("%lld sessions", sessions.count))
            }
        }
        .font(.system(size: 9.5, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .fixedSize()
    }

    @ViewBuilder
    private var days: some View {
        let days = week.days ?? []
        // A running week also shows the days still ahead.
        let count = week.running
            ? max(days.count, min(7, Int((week.end.timeIntervalSince(week.start) / 86_400).rounded(.up))))
            : max(days.count, 1)
        let slots = (0..<count).map { index -> ClaudeSliceChart.Slot in
            guard index < days.count else {
                let label = ClaudeSessionFormat.weekday(week.start.addingTimeInterval(Double(index) * 86_400))
                return .init(slice: nil, label: label, tooltip: L("Still ahead"))
            }
            let slice = days[index]
            let label = ClaudeSessionFormat.weekday(slice.start)
            let previous = days[..<index].last(where: { $0.pct != nil })?.pct
            let (spent, from, to) = sliceFigures(slice, previous: previous)
            return .init(slice: slice, label: label, tooltip: L("%1$@ · %2$@ · week %3$@ → %4$@", label, spent, from, to))
        }
        ClaudeSliceChart(
            slots: slots,
            axis: .perSlot,
            nowFraction: week.running ? fraction(of: Date(), from: week.start, to: week.end) : nil,
            spendLegend: L("spend per day"),
            lineLegend: L("week used → %@", ClaudeSessionFormat.percent(week.usedPct, week.usedQuality))
        )
    }

    @ViewBuilder
    private var sessions: some View {
        let all = week.sessions ?? []
        let top = all
            .filter { $0.weekQuality.isKnown && $0.weekPct != nil }
            .sorted { ($0.weekPct ?? 0) > ($1.weekPct ?? 0) }
            .prefix(Self.sessionRows)
        let largest = max(top.first?.weekPct ?? 1, 1)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(caps(L("Biggest sessions")))
                Spacer(minLength: 4)
                Text(caps(L("Share of week")))
            }
            .font(.system(size: 8.5, weight: .bold))
            .tracking(0.4)
            .foregroundStyle(.tertiary)
            .padding(.bottom, 1)

            ForEach(Array(top)) { session in
                HStack(spacing: 6) {
                    Text(ClaudeSessionFormat.sessionRange(start: session.start, end: session.end, inferred: false))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(money(session.spentUSD))
                        .font(.codeMono(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Meter(percent: (session.weekPct ?? 0) / largest * 100, hot: true)
                        .frame(width: 40, height: 4)
                    Text(ClaudeSessionFormat.percent(session.weekPct, session.weekQuality, signed: true))
                        .font(.codeMono(size: 9.5, weight: .semibold))
                        .foregroundStyle(Theme.brandAccentLight)
                        .frame(width: 32, alignment: .trailing)
                }
                .monospacedDigit()
                .accessibilityElement(children: .combine)
            }

            HStack(spacing: 4) {
                if all.count > top.count {
                    Text(L("%lld more", all.count - top.count))
                        .foregroundStyle(.tertiary)
                }
                if week.running {
                    if all.count > top.count { Text("·").foregroundStyle(.tertiary) }
                    Button(action: showSessions) {
                        Text(L("All in Sessions ›")).foregroundStyle(Theme.brandAccent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.system(size: 9.5, weight: .medium))
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private var models: some View {
        let models = week.models ?? []
        VStack(alignment: .leading, spacing: 2) {
            ForEach(models.prefix(Self.modelRows)) { model in
                ShareRow(title: model.model, detail: ClaudeSessionFormat.tokens(model.tokens), amount: money(model.spentUSD), share: share(model.spentUSD))
            }
            if models.count > Self.modelRows {
                let rest = models.dropFirst(Self.modelRows)
                let spent = rest.reduce(0) { $0 + $1.spentUSD }
                ShareRow(title: L("%lld more", rest.count), amount: money(spent), share: share(spent), dim: true)
            }
        }
    }

    private func share(_ spent: Double) -> Double {
        week.spentUSD > 0 ? spent / week.spentUSD : 0
    }

    private var warnings: [String] {
        guard let ranOut = week.ranOutAt else { return [] }
        return [L("Ran out %@", ClaudeSessionFormat.weekdayClock(ranOut))]
    }

    private var notes: [String] {
        var out: [String] = []
        if week.running {
            out.append(L("This week · since %@", ClaudeSessionFormat.weekdayClock(week.start)))
        }
        if week.endReason == .moved || week.endReason == .earlyReset {
            out.append(L("Cut short when Anthropic moved the weekly reset, so it has no full-week value"))
        }
        if week.startInferred {
            out.append(L("No readings at the start of this week; its dates are inferred"))
        }
        return out
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
