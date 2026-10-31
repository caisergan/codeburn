import SwiftUI

// Views for the Claude window warmer: the Warm button and its result line in
// the Plan header, and the Window Warmer section of Settings › Claude. See
// docs/design/claude-window-warmer.md.

// MARK: - Plan header

/// The Warm button between the plan name and the reset text. Enabled only
/// while no 5-hour window is running; hidden when nothing can warm.
struct ClaudeWarmButton: View {
    /// nil while the 5-hour reading is not loaded.
    let isIdle: Bool?
    let fiveHourResetsAt: Date?

    var warmer: WindowWarmer = .shared

    var body: some View {
        if let runner = warmer.selectedRunner {
            let enabled = isIdle == true && runner.usable && !warmer.isWarming
            Button {
                guard enabled else { return }
                Task { await warmer.warmNow() }
            } label: {
                HStack(spacing: 3) {
                    if warmer.isWarming {
                        ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 9, height: 9)
                    } else {
                        Image(systemName: "flame.fill").font(.system(size: 8.5, weight: .semibold))
                    }
                    Text(warmer.isWarming ? L("Warming…") : L("Warm"))
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(enabled ? Theme.brandAccent.opacity(0.16) : Color.secondary.opacity(0.12))
                )
                .foregroundStyle(enabled ? AnyShapeStyle(Theme.brandAccent) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            // Not `.disabled`: a disabled control shows no tooltip, and the
            // tooltip is what explains why it is greyed out.
            .help(tooltip(runner: runner))
            .accessibilityLabel(L("Warm"))
            .accessibilityHint(tooltip(runner: runner))
            .task { await warmer.refreshStatus() }
        }
    }

    private func tooltip(runner: WarmRunner) -> String {
        if warmer.isWarming { return L("Warming…") }
        guard runner.usable else { return L("%@ can't warm right now. See Settings › Claude › Window Warmer.", runner.name) }
        switch isIdle {
        case nil:
            return L("Waiting for Claude usage")
        case false?:
            if let resets = fiveHourResetsAt {
                return L("A 5-hour window is already running. It resets at %@, then you can warm a new one.", WindowWarmer.clockLabel(resets))
            }
            return L("A 5-hour window is already running.")
        case true?:
            return L("Start a 5-hour window now on %@", runner.name)
        }
    }
}

/// "Next warm 07:00" in place of the reset text while no window runs.
struct ClaudeNextWarmLabel: View {
    let next: Date

    var body: some View {
        Text(L("Next warm %@", Self.label(next)))
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
    }

    static func label(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return WindowWarmer.clockLabel(date) }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

/// The result of a click, for ten seconds under the header row.
struct ClaudeWarmBannerRow: View {
    var warmer: WindowWarmer = .shared

    var body: some View {
        if let banner = warmer.banner {
            let success = banner.kind == .success
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 10))
                Text(banner.message)
                    .font(.system(size: 10.5))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if banner.offerLocal {
                    Button(L("Warm on this Mac")) {
                        Task { await warmer.warmNow(onThisMac: true) }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.brandAccent)
                }
            }
            .foregroundStyle(success ? Color.green : Color.red.opacity(0.9))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill((success ? Color.green : Color.red).opacity(0.1))
            )
            .transition(.opacity)
        }
    }
}

// MARK: - Settings › Claude › Window Warmer

struct ClaudeWarmSettingsSection: View {
    @State private var showHistory = false

    var warmer: WindowWarmer = .shared
    private var prefs: WarmSchedulePrefs { warmer.prefs }

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { prefs.enabled }, set: { value in warmer.update { $0.enabled = value } })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("Warm on schedule"))
                    Text(L("Start a 5-hour window at the times below"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            runnerPicker
            runnerStatus
            if showHistory {
                historyRows
            }

            LabeledContent(L("Start a window at")) {
                Text(L("%1$lld of %2$lld", prefs.times.count, WarmSchedulePrefs.maxTimes))
                    .foregroundStyle(.secondary)
            }
            .disabled(!prefs.enabled)
            ForEach(prefs.times, id: \.self) { time in
                WarmTimeRow(time: time, warmer: warmer)
            }
            .disabled(!prefs.enabled)
            Button {
                warmer.update { $0.addTime() }
            } label: {
                Label(addLabel, systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderless)
            .disabled(!prefs.enabled || !prefs.canAddTime)

            WarmDaysRow(warmer: warmer)
                .disabled(!prefs.enabled)
            WarmDayPreview(prefs: prefs)
                .opacity(prefs.enabled ? 1 : 0.45)
        } header: {
            Text(L("Window Warmer"))
        } footer: {
            Text(L("Sends one short Claude Code message at each time, only when no 5-hour window is running. It uses your own Claude Code login on the device that runs it; CodeBurn never sends messages with your Claude token. Off by default."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .task { await warmer.refreshStatus(force: true) }
    }

    private var addLabel: String {
        prefs.canAddTime
            ? L("Add time (adds %@)", WarmSchedulePrefs.clock(prefs.nextTimeToAdd))
            : L("Add time (4 at most: a day holds 4.8 windows)")
    }

    @ViewBuilder
    private var runnerPicker: some View {
        let runners = warmer.runners
        Picker(L("Run on"), selection: Binding(
            get: { warmer.selectedRunner?.id ?? "" },
            set: { id in warmer.update { $0.runnerId = id } }
        )) {
            if runners.isEmpty {
                Text(L("No device can warm yet")).tag("")
            }
            ForEach(runners) { runner in
                Text(runnerLabel(runner)).tag(runner.id)
            }
        }
        .pickerStyle(.menu)
    }

    private func runnerLabel(_ runner: WarmRunner) -> String {
        if runner.isLocal { return runner.name }
        switch runner.state {
        case "ok": return L("%@ (paired)", runner.name)
        case "not_allowed": return L("%@ (needs --allow-warm)", runner.name)
        default: return L("%@ (unreachable)", runner.name)
        }
    }

    @ViewBuilder
    private var runnerStatus: some View {
        if let runner = warmer.selectedRunner {
            let (color, text) = statusLine(runner)
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if !warmer.history.isEmpty {
                    Button(showHistory ? L("Hide history") : L("History")) { showHistory.toggle() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11.5))
                }
            }
        } else {
            Text(L("Install Claude Code on this Mac, or pair a device that runs `codeburn share --always --allow-warm`."))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
    }

    private func statusLine(_ runner: WarmRunner) -> (Color, String) {
        if let unsynced = warmer.unsyncedDeviceName, unsynced == runner.name {
            return (.orange, L("Not synced to %@, will retry", runner.name))
        }
        if runner.isLocal {
            return (.orange, L("Only warms while this Mac is awake. A missed warm runs on wake if it's less than 30 minutes late."))
        }
        switch runner.state {
        case "ok":
            var parts = [L("Ready")]
            if runner.status?.signedIn == false {
                return (.red, L("Claude Code isn't signed in on %@", runner.name))
            }
            if runner.status?.signedIn == true { parts.append(L("Claude Code signed in")) }
            if let last = runner.status?.history.first {
                parts.append(L("last warm %1$@: %2$@", Self.when(last.at), Self.outcomeLabel(last)))
            }
            return (.green, parts.joined(separator: " · "))
        case "not_allowed":
            return (.orange, L("Run `codeburn share --always --allow-warm` on %@ to let it warm", runner.name))
        case "unauthorized":
            return (.red, L("%@ no longer accepts this Mac. Pair it again.", runner.name))
        default:
            return (.red, L("Can't reach %@ right now", runner.name))
        }
    }

    private var historyRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(warmer.history.prefix(10)) { result in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Self.when(result.at))
                        .foregroundStyle(.secondary)
                        .frame(width: 120, alignment: .leading)
                    Text(Self.outcomeLabel(result))
                        .font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Self.outcomeColor(result).opacity(0.16)))
                        .foregroundStyle(Self.outcomeColor(result))
                    Text(Self.reasonLabel(result))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .font(.system(size: 11.5))
            }
        }
    }

    static func when(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return L("Today %@", WindowWarmer.clockLabel(date)) }
        if Calendar.current.isDateInYesterday(date) { return L("Yesterday %@", WindowWarmer.clockLabel(date)) }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    static func outcomeLabel(_ result: WarmResultDTO) -> String {
        switch result.outcome {
        case "started": return L("started")
        case "skipped": return L("skipped")
        default: return L("failed")
        }
    }

    static func outcomeColor(_ result: WarmResultDTO) -> Color {
        switch result.outcome {
        case "started": return .green
        case "skipped": return .secondary
        default: return .red
        }
    }

    static func reasonLabel(_ result: WarmResultDTO) -> String {
        switch result.reason {
        case nil:
            if let resets = result.resetsAt {
                let start = resets.addingTimeInterval(-Double(WarmSchedulePrefs.windowMinutes) * 60)
                return "\(WindowWarmer.clockLabel(start)) – \(WindowWarmer.clockLabel(resets))"
            }
            return L("Warm sent")
        case "window_running":
            if let resets = result.resetsAt { return L("window running, resets %@", WindowWarmer.clockLabel(resets)) }
            return L("window running")
        case "weekly_full": return L("weekly limit reached")
        case "usage_unavailable": return L("couldn't read Claude usage")
        case "claude_not_found": return L("Claude Code isn't installed there")
        case "no_window_yet": return L("sent; the window wasn't showing yet")
        default: return result.detail ?? L("Claude Code didn't answer")
        }
    }
}

private struct WarmTimeRow: View {
    let time: Int

    var warmer: WindowWarmer = .shared

    var body: some View {
        HStack(spacing: 10) {
            DatePicker(L("Time"), selection: Binding(
                get: { Self.date(for: time) },
                set: { date in warmer.update { $0.moveTime(time, to: Self.minutes(of: date)) } }
            ), displayedComponents: .hourAndMinute)
            .labelsHidden()
            .fixedSize()
            Text(L("→ resets %@", WarmSchedulePrefs.clock(time + WarmSchedulePrefs.windowMinutes)))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
            if let previous = warmer.prefs.overlappedTime(for: time) {
                Text(L("inside the %@ window: only fires if that one wasn't started", WarmSchedulePrefs.clock(previous)))
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            } else if WarmSchedulePrefs.peakHours.contains(time) {
                Text(L("during peak hours"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button {
                warmer.update { $0.removeTime(time) }
            } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(L("Remove"))
            .accessibilityLabel(L("Remove"))
        }
    }

    static func date(for minutes: Int) -> Date {
        Calendar.current.date(byAdding: .minute, value: minutes, to: Calendar.current.startOfDay(for: Date())) ?? Date()
    }

    static func minutes(of date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}

private struct WarmDaysRow: View {
    var warmer: WindowWarmer = .shared

    private static let everyDay: Set<Int> = Set(0...6)
    private static let weekdays: Set<Int> = Set(0...4)
    private static let weekends: Set<Int> = [5, 6]

    var body: some View {
        let days = warmer.prefs.days
        HStack(spacing: 6) {
            Text(L("Days"))
            Spacer()
            ForEach(0..<7, id: \.self) { index in
                let on = days.contains(index)
                Button {
                    warmer.update { prefs in
                        if on { prefs.days.remove(index) } else { prefs.days.insert(index) }
                    }
                } label: {
                    Text(Self.initial(index))
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(on ? Color.accentColor : Color.clear))
                        .overlay(Circle().stroke(on ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: 1))
                        .foregroundStyle(on ? Color.white : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.fullName(index))
                .accessibilityValue(on ? L("On") : L("Off"))
            }
            Menu(presetLabel(days)) {
                Button(L("Every day")) { warmer.update { $0.days = Self.everyDay } }
                Button(L("Weekdays")) { warmer.update { $0.days = Self.weekdays } }
                Button(L("Weekends")) { warmer.update { $0.days = Self.weekends } }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func presetLabel(_ days: Set<Int>) -> String {
        switch days {
        case Self.everyDay: return L("Every day")
        case Self.weekdays: return L("Weekdays")
        case Self.weekends: return L("Weekends")
        default: return L("Custom")
        }
    }

    /// 0 = Monday; the calendar's symbols start on Sunday.
    static func initial(_ index: Int) -> String {
        Calendar.current.veryShortWeekdaySymbols[(index + 1) % 7]
    }

    static func fullName(_ index: Int) -> String {
        Calendar.current.weekdaySymbols[(index + 1) % 7]
    }
}

/// The day at a glance: each scheduled window, overlaps striped, peak hours
/// outlined, and the current time.
private struct WarmDayPreview: View {
    let prefs: WarmSchedulePrefs

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("Your day"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Canvas { ctx, size in
                    draw(in: &ctx, size: size, now: context.date)
                }
            }
            .frame(height: 26)
            .accessibilityLabel(L("Scheduled windows"))
            .accessibilityValue(prefs.sortedTimes.map { "\(WarmSchedulePrefs.clock($0))–\(WarmSchedulePrefs.clock($0 + WarmSchedulePrefs.windowMinutes))" }.joined(separator: ", "))
            HStack(spacing: 0) {
                ForEach([0, 6, 12, 18, 24], id: \.self) { hour in
                    Text(String(format: "%02d", hour))
                        .font(.system(size: 9.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                    if hour < 24 { Spacer(minLength: 0) }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func draw(in ctx: inout GraphicsContext, size: CGSize, now: Date) {
        let day = 24.0 * 60
        let x = { (minutes: Double) in size.width * minutes / day }
        ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 5), with: .color(.secondary.opacity(0.1)))
        let peak = CGRect(x: x(Double(WarmSchedulePrefs.peakHours.lowerBound)), y: 0,
                          width: x(Double(WarmSchedulePrefs.peakHours.count)), height: size.height)
        ctx.stroke(Path(peak), with: .color(.secondary.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        for time in prefs.sortedTimes {
            let overlap = prefs.overlappedTime(for: time) != nil
            let color: Color = overlap ? .orange.opacity(0.55) : Theme.brandAccent
            let start = Double(time)
            let end = start + Double(WarmSchedulePrefs.windowMinutes)
            var segments = [(start, min(end, day))]
            if end > day { segments.append((0, end - day)) }
            for (a, b) in segments {
                let rect = CGRect(x: x(a) + 1, y: 4, width: max(2, x(b) - x(a) - 2), height: size.height - 8)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(color))
            }
        }
        let calendar = Calendar.current
        let minutes = now.timeIntervalSince(calendar.startOfDay(for: now)) / 60
        ctx.fill(Path(CGRect(x: x(minutes) - 1, y: 0, width: 2, height: size.height)), with: .color(.primary.opacity(0.75)))
    }
}
