import SwiftUI

// Views for the Antigravity window warmer: the Warm button and its result line
// in the Antigravity Plan header, and the Window Warmer section of
// Settings › Antigravity. The schedule rows are the Claude warmer's.

// MARK: - Plan header

struct AntigravityWarmButton: View {
    let usage: AntigravityUsage

    var warmer: AntigravityWarmer = .shared

    var body: some View {
        if warmer.canWarm {
            let idle = warmer.idleGroups(in: usage)
            let enabled = !idle.isEmpty && !warmer.isWarming
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
            // Not `.disabled`: a disabled control shows no tooltip.
            .help(tooltip(idle: idle))
            .accessibilityLabel(L("Warm"))
            .accessibilityHint(tooltip(idle: idle))
        }
    }

    private func tooltip(idle: [AntigravityUsage.Group]) -> String {
        if warmer.isWarming { return L("Warming…") }
        if warmer.prefs.groups.isEmpty {
            return L("Pick a group to warm in Settings › Antigravity › Window Warmer.")
        }
        if idle.isEmpty {
            return L("Every group you warm already has a 5-hour window running, or its weekly limit is used up.")
        }
        return L("Start a 5-hour window now for %@, with one short message from agy", idle.map(\.name).joined(separator: ", "))
    }
}

struct AntigravityWarmBannerRow: View {
    var warmer: AntigravityWarmer = .shared

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

// MARK: - Settings › Antigravity › Window Warmer

struct AntigravityWarmSettingsSection: View {
    @Environment(AppStore.self) private var store
    @State private var showHistory = false

    var warmer: AntigravityWarmer = .shared
    private var prefs: AntigravityWarmPrefs { warmer.prefs }
    private var schedule: WarmSchedulePrefs { prefs.schedule }

    /// The groups the quota reading lists, or the two Antigravity has today
    /// while there is no reading.
    private var groups: [(id: String, name: String)] {
        let read = store.antigravityUsage?.groups.map { ($0.id, $0.name) } ?? []
        if !read.isEmpty { return read }
        return [("gemini", L("Gemini models")), ("3p", L("Claude and GPT models"))]
    }

    var body: some View {
        Section {
            statusRow
            if showHistory { historyRows }

            ForEach(groups, id: \.id) { group in
                Toggle(isOn: Binding(
                    get: { prefs.groups.contains(group.id) },
                    set: { on in warmer.update { if on { $0.groups.insert(group.id) } else { $0.groups.remove(group.id) } } }
                )) {
                    Text(L("Warm %@", group.name))
                }
            }

            Toggle(isOn: Binding(get: { schedule.enabled }, set: { value in warmer.updateSchedule { $0.enabled = value } })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("Warm on schedule"))
                    Text(L("Start a 5-hour window at the times below"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: Binding(get: { schedule.autoEnabled }, set: { value in warmer.updateSchedule { $0.autoEnabled = value } })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("Warm again right after each reset"))
                    Text(L("Between %1$@ and %2$@, only after a window you used, at most %3$lld a day per group.",
                           WarmSchedulePrefs.clock(WarmSchedulePrefs.autoHours.lowerBound), "24:00", WarmSchedulePrefs.autoDailyCap))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            LabeledContent(L("Start a window at")) {
                Text(L("%1$lld of %2$lld", schedule.times.count, WarmSchedulePrefs.maxTimes))
                    .foregroundStyle(.secondary)
            }
            .disabled(!schedule.enabled)
            ForEach(schedule.times, id: \.self) { time in
                WarmTimeRow(time: time, prefs: schedule) { change in warmer.updateSchedule(change) }
            }
            .disabled(!schedule.enabled)
            Button {
                warmer.updateSchedule { $0.addTime() }
            } label: {
                Label(schedule.canAddTime
                      ? L("Add time (adds %@)", WarmSchedulePrefs.clock(schedule.nextTimeToAdd))
                      : L("Add time (4 at most: a day holds 4.8 windows)"),
                      systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderless)
            .disabled(!schedule.enabled || !schedule.canAddTime)

            WarmDaysRow(days: schedule.days) { change in warmer.updateSchedule(change) }
                .disabled(!schedule.enabled)
            WarmDayPreview(prefs: schedule)
                .opacity(schedule.enabled ? 1 : 0.45)
        } header: {
            Text(L("Window Warmer"))
        } footer: {
            Text(L("Each warm is one short message sent by your own signed-in Antigravity CLI (agy), only when that group has no 5-hour window running. CodeBurn reads quota with your Antigravity sign-in but never sends messages with it. A warm uses about %lld%% of the group's weekly limit and shows up as a short agy conversation. Off by default.", 1))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        if warmer.canWarm {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Circle().fill(Color.orange).frame(width: 7, height: 7)
                Text(statusText)
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
            Text(L("Install the Antigravity CLI (agy) and sign in to it to warm windows."))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        var parts = [L("Runs on this Mac with agy, only while it's awake. A missed warm runs on wake if it's less than 30 minutes late.")]
        if let last = warmer.history.first {
            parts.append(L("last warm %1$@ %2$@: %3$@", ClaudeWarmSettingsSection.when(last.at),
                           Self.triggerLabel(last.trigger), Self.outcomeLabel(last.outcome)))
        }
        return parts.joined(separator: " · ")
    }

    private var historyRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(warmer.history.prefix(10)) { result in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ClaudeWarmSettingsSection.when(result.at))
                        .foregroundStyle(.secondary)
                        .frame(width: 110, alignment: .leading)
                    Text(Self.triggerLabel(result.trigger))
                        .foregroundStyle(.tertiary)
                        .frame(width: 60, alignment: .leading)
                    Text(Self.outcomeLabel(result.outcome))
                        .font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Self.outcomeColor(result.outcome).opacity(0.16)))
                        .foregroundStyle(Self.outcomeColor(result.outcome))
                    Text(AntigravityWarmer.reasonLabel(result))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .font(.system(size: 11.5))
            }
        }
    }

    static func triggerLabel(_ trigger: String) -> String {
        switch trigger {
        case "auto": return L("auto")
        case "scheduled": return L("scheduled")
        default: return L("manual")
        }
    }

    static func outcomeLabel(_ outcome: String) -> String {
        switch outcome {
        case "started": return L("started")
        case "skipped": return L("skipped")
        default: return L("failed")
        }
    }

    static func outcomeColor(_ outcome: String) -> Color {
        switch outcome {
        case "started": return .green
        case "skipped": return .secondary
        default: return .red
        }
    }
}
