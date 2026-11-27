import AppKit
import Foundation
import Observation

// The Antigravity window warmer: start a quota group's 5-hour window at chosen
// times, right after a reset, or on demand. Like the Claude warmer
// (docs/design/claude-window-warmer.md), every warm is one short message sent
// by the user's own signed-in, unmodified `agy` CLI. CodeBurn never sends a
// chat message with the Antigravity token; it only reads quota with it.
// It runs on this Mac only: the sign-in and `agy` live here.

// MARK: - Prefs and results

struct AntigravityWarmPrefs: Codable, Equatable, Sendable {
    /// Times, days, on/off and auto-warm, with the Claude warmer's rules
    /// (`runnerId` is unused: this Mac always runs Antigravity warms).
    var schedule = WarmSchedulePrefs()
    /// Quota group ids to warm ("gemini", "3p").
    var groups: Set<String> = ["gemini"]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schedule = try c.decodeIfPresent(WarmSchedulePrefs.self, forKey: .schedule) ?? WarmSchedulePrefs()
        groups = try c.decodeIfPresent(Set<String>.self, forKey: .groups) ?? ["gemini"]
    }
}

struct AntigravityWarmResult: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    let at: Date
    /// manual, scheduled or auto.
    let trigger: String
    let group: String
    let groupName: String
    /// started, skipped or failed.
    let outcome: String
    /// window_running, weekly_full, usage_unavailable, agy_not_found,
    /// signed_out, no_model, send_failed, no_window_yet; nil when started.
    let reason: String?
    let detail: String?
    var resetsAt: Date?
}

/// The 5-hour window a group was last seen running, for auto-warm: when it
/// resets, and the highest percent it was read at.
struct AntigravityTrackedWindow: Codable, Equatable, Sendable {
    let resetsAt: Date
    var maxPercent: Double
}

// MARK: - Pure rules (tested)

enum AntigravityWarmRules {
    /// The cheapest model of a group that `agy models` lists. Quota is spent
    /// in proportion to token cost, so a Flash or GPT-OSS model at low effort
    /// starts the window for the least. `groupModels` are the group's display
    /// names; `available` is `(id, display name)` from `agy models`.
    static func warmModel(groupId: String, groupModels: [String], available: [(id: String, name: String)]) -> String? {
        func base(_ name: String) -> String {
            guard let paren = name.firstIndex(of: "(") else { return name.lowercased() }
            return name[..<paren].trimmingCharacters(in: .whitespaces).lowercased()
        }
        let wanted = Set(groupModels.map { $0.lowercased() })
        var candidates = available.filter { wanted.contains(base($0.name)) }
        if candidates.isEmpty {
            // Legacy payloads carry no model list: fall back on the group id.
            let hint = groupId == "gemini" ? "flash" : groupId == "3p" ? "gpt-oss" : nil
            if let hint { candidates = available.filter { $0.name.lowercased().contains(hint) } }
        }
        let families = ["flash", "gpt-oss", "haiku", "sonnet"]
        let efforts = ["(low)", "(medium)", "(high)", "(xhigh)"]
        func rank(_ name: String) -> (Int, Int) {
            let lower = name.lowercased()
            let family = families.firstIndex { lower.contains($0) } ?? families.count
            let effort = efforts.firstIndex { lower.contains($0) } ?? efforts.count
            return (family, effort)
        }
        return candidates.min { rank($0.name) < rank($1.name) }?.id
    }

    /// `agy models` lines: `<id>\t<display name>`.
    static func parseModels(_ output: String) -> [(id: String, name: String)] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, !parts[0].contains(" ") else { return nil }
            return (parts[0], parts[1])
        }
    }

    /// Whether a group's reset at `resetsAt` should be auto-warmed at `now`:
    /// auto-warm on, the group selected, within 10 minutes after the reset,
    /// the reset inside the active hours, the window read above 2%, and
    /// fewer than five automatic or scheduled starts today.
    static func shouldAutoWarm(prefs: AntigravityWarmPrefs, group: String, window: AntigravityTrackedWindow,
                               history: [AntigravityWarmResult], now: Date, calendar: Calendar = .current) -> Bool {
        guard prefs.schedule.autoEnabled, prefs.groups.contains(group) else { return false }
        let late = now.timeIntervalSince(window.resetsAt)
        guard late >= 60, late <= 10 * 60 else { return false }
        guard window.maxPercent > WarmSchedulePrefs.autoMinPercent else { return false }
        let minutes = Int(window.resetsAt.timeIntervalSince(calendar.startOfDay(for: window.resetsAt)) / 60)
        guard WarmSchedulePrefs.autoHours.contains(minutes) else { return false }
        return startsToday(history: history, group: group, now: now, calendar: calendar) < WarmSchedulePrefs.autoDailyCap
    }

    static func startsToday(history: [AntigravityWarmResult], group: String, now: Date, calendar: Calendar = .current) -> Int {
        history.filter {
            $0.group == group && $0.trigger != "manual" && $0.outcome == "started" && calendar.isDate($0.at, inSameDayAs: now)
        }.count
    }

    /// The reset auto-warm will act on for the Plan header: the earliest
    /// running window among the selected groups that passes every rule but
    /// the idle check.
    static func autoWarmAt(prefs: AntigravityWarmPrefs, usage: AntigravityUsage, history: [AntigravityWarmResult],
                           now: Date, calendar: Calendar = .current) -> Date? {
        guard prefs.schedule.autoEnabled else { return nil }
        return usage.groups.compactMap { group -> Date? in
            guard prefs.groups.contains(group.id), !group.isFiveHourIdle(now: now),
                  let bucket = group.fiveHour, let resets = bucket.resetsAt, resets > now else { return nil }
            let window = AntigravityTrackedWindow(resetsAt: resets, maxPercent: bucket.usedPercent)
            let at = resets.addingTimeInterval(60)
            return shouldAutoWarm(prefs: prefs, group: group.id, window: window, history: history, now: at, calendar: calendar) ? resets : nil
        }.min()
    }

    /// The `agy` warm command: one short prompt, no slash commands, a time
    /// limit, JSON out. The prompt is attached to `--print` so no flag can
    /// take it as a value.
    static func warmArguments(model: String) -> [String] {
        ["--model", model, "--disable-slash-commands", "--print-timeout", "90s",
         "--output-format", "json", "--print=Reply with OK."]
    }

    /// Variables that would make `agy` use an API key or Vertex instead of
    /// the user's own sign-in, which is what carries the 5-hour window.
    static let strippedEnvironment: Set<String> = [
        "GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_GENAI_USE_VERTEXAI",
        "GOOGLE_CLOUD_PROJECT", "GOOGLE_APPLICATION_CREDENTIALS",
    ]

    /// Reads `agy --print --output-format json`: `status` SUCCESS is a sent
    /// warm; anything else is a failure with the CLI's own words.
    static func sendOutcome(exitCode: Int32, stdout: String, stderr: String) -> (ok: Bool, reason: String?, detail: String?) {
        let json = stdout.split(separator: "\n").last.flatMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
        if exitCode == 0, (json?["status"] as? String)?.uppercased() == "SUCCESS" { return (true, nil, nil) }
        let message = ([stderr, (json?["error"] as? String) ?? "", stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "")
            .split(separator: "\n").last.map(String.init) ?? ""
        let lower = message.lowercased()
        if lower.contains("not logged in") || lower.contains("sign in") || lower.contains("log in") {
            return (false, "signed_out", nil)
        }
        let detail = message.isEmpty ? nil : String(AntigravitySubscriptionService.sanitizeForLog(message).prefix(160))
        return (false, "send_failed", detail)
    }
}

// MARK: - Service

@MainActor
@Observable
final class AntigravityWarmer {
    static let shared = AntigravityWarmer()

    struct Banner: Equatable {
        enum Kind { case success, failure }
        let kind: Kind
        let message: String
        let id = UUID()
    }

    private(set) var prefs: AntigravityWarmPrefs
    private(set) var history: [AntigravityWarmResult]
    private(set) var isWarming = false
    private(set) var banner: Banner?
    /// nil until checked; checked on start and before each warm.
    private(set) var agyPath: String?

    @ObservationIgnored weak var store: AppStore?
    @ObservationIgnored private var windows: [String: AntigravityTrackedWindow]
    @ObservationIgnored private var availableModels: [(id: String, name: String)]?
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var started = false
    @ObservationIgnored private let defaults: UserDefaults

    private static let prefsKey = "antigravityWindowWarmer.prefs"
    private static let historyKey = "antigravityWindowWarmer.history"
    private static let windowsKey = "antigravityWindowWarmer.windows"
    private static let lastSlotKey = "antigravityWindowWarmer.lastSlot"
    private static let historyLimit = 20

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let decoder = JSONDecoder()
        prefs = defaults.data(forKey: Self.prefsKey).flatMap { try? decoder.decode(AntigravityWarmPrefs.self, from: $0) }
            ?? AntigravityWarmPrefs()
        history = defaults.data(forKey: Self.historyKey).flatMap { try? decoder.decode([AntigravityWarmResult].self, from: $0) } ?? []
        windows = defaults.data(forKey: Self.windowsKey).flatMap { try? decoder.decode([String: AntigravityTrackedWindow].self, from: $0) } ?? [:]
        agyPath = AntigravityInstall.agyPath()
    }

    var canWarm: Bool { agyPath != nil }

    func nextWarm(after now: Date = Date()) -> Date? {
        prefs.schedule.nextWarm(after: now)
    }

    func autoWarmAt(usage: AntigravityUsage, now: Date = Date()) -> Date? {
        AntigravityWarmRules.autoWarmAt(prefs: prefs, usage: usage, history: history, now: now)
    }

    /// The selected groups present in `usage` whose 5-hour window is idle.
    func idleGroups(in usage: AntigravityUsage, now: Date = Date()) -> [AntigravityUsage.Group] {
        usage.groups.filter { prefs.groups.contains($0.id) && $0.isFiveHourIdle(now: now) && !$0.isWeeklyFull }
    }

    // MARK: Lifecycle

    func start(store: AppStore) {
        self.store = store
        guard !started else { return }
        started = true
        let timer = Timer(timeInterval: 60, repeats: true) { _ in
            Task { @MainActor in await AntigravityWarmer.shared.tick() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await AntigravityWarmer.shared.tick() }
        }
    }

    func update(_ change: (inout AntigravityWarmPrefs) -> Void) {
        var next = prefs
        change(&next)
        guard next != prefs else { return }
        prefs = next
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: Self.prefsKey) }
    }

    func updateSchedule(_ change: (inout WarmSchedulePrefs) -> Void) {
        update { change(&$0.schedule) }
    }

    // MARK: Tracking and the timer

    /// Remembers each running 5-hour window and its highest reading, so the
    /// reset can be auto-warmed after a window the user really used.
    func track(_ usage: AntigravityUsage, now: Date = Date()) {
        var changed = false
        for group in usage.groups {
            guard !group.isFiveHourIdle(now: now), let bucket = group.fiveHour, let resets = bucket.resetsAt, resets > now else { continue }
            var window = windows[group.id]
            if window == nil || abs(window!.resetsAt.timeIntervalSince(resets)) > 120 {
                window = AntigravityTrackedWindow(resetsAt: resets, maxPercent: bucket.usedPercent)
                changed = true
            } else if bucket.usedPercent > window!.maxPercent {
                window!.maxPercent = bucket.usedPercent
                changed = true
            }
            windows[group.id] = window
        }
        if changed { saveWindows() }
    }

    private func saveWindows() {
        if let data = try? JSONEncoder().encode(windows) { defaults.set(data, forKey: Self.windowsKey) }
    }

    /// Runs the schedule and auto-warm while this Mac is awake. A scheduled
    /// warm missed during sleep runs on wake within 30 minutes; a reset
    /// missed by more than 10 minutes is not warmed late.
    func tick(now: Date = Date()) async {
        guard let store, !isWarming else { return }
        if let usage = store.antigravityUsage { track(usage, now: now) }

        var due: [String: String] = [:]   // group → trigger
        if let slot = prefs.schedule.dueSlot(at: now), defaults.string(forKey: Self.lastSlotKey) != slot {
            defaults.set(slot, forKey: Self.lastSlotKey)
            for group in prefs.groups { due[group] = "scheduled" }
        }
        for (group, window) in windows where now.timeIntervalSince(window.resetsAt) >= 60 {
            // Decided once per reset, whatever the answer.
            windows[group] = nil
            saveWindows()
            if due[group] == nil,
               AntigravityWarmRules.shouldAutoWarm(prefs: prefs, group: group, window: window, history: history, now: now) {
                due[group] = "auto"
            }
        }
        guard !due.isEmpty else { return }
        for trigger in Set(due.values).sorted() {
            let groups = Set(due.filter { $0.value == trigger }.keys)
            _ = await warm(groups: groups, trigger: trigger)
        }
    }

    // MARK: Warm

    /// The Warm button: every selected group whose window is idle.
    func warmNow() async {
        guard !isWarming else { return }
        banner = nil
        let results = await warm(groups: prefs.groups, trigger: "manual")
        show(Self.banner(for: results))
    }

    /// Reads quota fresh, then sends one warm per idle group in `groups`.
    /// A group with a running window, a full week or no reading is skipped
    /// and nothing is sent for it.
    @discardableResult
    func warm(groups: Set<String>, trigger: String, now: () -> Date = Date.init) async -> [AntigravityWarmResult] {
        guard !isWarming, let store, !groups.isEmpty else { return [] }
        isWarming = true
        defer { isWarming = false }
        agyPath = AntigravityInstall.agyPath()

        await store.refreshAntigravity()
        guard let usage = store.antigravityUsage, now().timeIntervalSince(usage.fetchedAt) < 120 else {
            return record(groups.sorted().map {
                result(trigger: trigger, group: $0, name: $0, outcome: "skipped", reason: "usage_unavailable", detail: store.antigravityError)
            })
        }
        var results: [AntigravityWarmResult] = []
        var sent: [String] = []
        for group in usage.groups where groups.contains(group.id) {
            if group.isWeeklyFull {
                results.append(result(trigger: trigger, group: group.id, name: group.name, outcome: "skipped", reason: "weekly_full"))
                continue
            }
            if !group.isFiveHourIdle(now: now()) {
                var skipped = result(trigger: trigger, group: group.id, name: group.name, outcome: "skipped", reason: "window_running")
                skipped.resetsAt = group.fiveHour?.resetsAt
                results.append(skipped)
                continue
            }
            guard let agy = agyPath else {
                results.append(result(trigger: trigger, group: group.id, name: group.name, outcome: "failed", reason: "agy_not_found"))
                continue
            }
            guard let model = await model(for: group, agy: agy) else {
                results.append(result(trigger: trigger, group: group.id, name: group.name, outcome: "failed", reason: "no_model"))
                continue
            }
            let outcome = await Self.send(agy: agy, model: model)
            if outcome.ok {
                sent.append(group.id)
                results.append(result(trigger: trigger, group: group.id, name: group.name, outcome: "started", reason: nil))
            } else {
                results.append(result(trigger: trigger, group: group.id, name: group.name, outcome: "failed",
                                      reason: outcome.reason, detail: outcome.detail))
            }
        }
        if !sent.isEmpty {
            // Success is a window that now reads as running, with its reset.
            await store.refreshAntigravity()
            let after = store.antigravityUsage
            if let after { track(after, now: now()) }
            for index in results.indices where results[index].outcome == "started" {
                let group = after?.groups.first { $0.id == results[index].group }
                if let group, !group.isFiveHourIdle(now: now()), let resets = group.fiveHour?.resetsAt {
                    results[index].resetsAt = resets
                } else {
                    results[index] = AntigravityWarmResult(
                        at: results[index].at, trigger: trigger, group: results[index].group,
                        groupName: results[index].groupName, outcome: "started", reason: "no_window_yet", detail: nil)
                }
            }
        }
        return record(results)
    }

    private func result(trigger: String, group: String, name: String, outcome: String, reason: String?, detail: String? = nil) -> AntigravityWarmResult {
        AntigravityWarmResult(at: Date(), trigger: trigger, group: group, groupName: name, outcome: outcome, reason: reason, detail: detail)
    }

    private func record(_ results: [AntigravityWarmResult]) -> [AntigravityWarmResult] {
        guard !results.isEmpty else { return results }
        history = Array((results.reversed() + history).prefix(Self.historyLimit))
        if let data = try? JSONEncoder().encode(history) { defaults.set(data, forKey: Self.historyKey) }
        for result in results {
            NSLog("CodeBurn: Antigravity warm %@ %@ %@ %@", result.trigger, result.group, result.outcome, result.reason ?? "")
        }
        return results
    }

    private func model(for group: AntigravityUsage.Group, agy: String) async -> String? {
        if availableModels == nil || availableModels?.isEmpty == true {
            availableModels = await Self.listModels(agy: agy)
        }
        return AntigravityWarmRules.warmModel(groupId: group.id, groupModels: group.models, available: availableModels ?? [])
    }

    // MARK: agy

    private static func process(agy: String, arguments: [String]) -> (Process, URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: agy)
        process.arguments = arguments
        // An empty directory, so the warm sees no project files.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codeburn-agy-warm-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        for key in AntigravityWarmRules.strippedEnvironment { environment[key] = nil }
        process.environment = environment
        return (process, directory)
    }

    private static func listModels(agy: String) async -> [(id: String, name: String)] {
        let (process, directory) = process(agy: agy, arguments: ["models"])
        defer { try? FileManager.default.removeItem(at: directory) }
        guard let result = try? await DataClient.runProcess(process, timeoutSeconds: 30, label: "agy models"),
              result.exitCode == 0 else { return [] }
        return AntigravityWarmRules.parseModels(String(decoding: result.stdout, as: UTF8.self))
    }

    private static func send(agy: String, model: String) async -> (ok: Bool, reason: String?, detail: String?) {
        let (process, directory) = process(agy: agy, arguments: AntigravityWarmRules.warmArguments(model: model))
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let result = try await DataClient.runProcess(process, timeoutSeconds: 120, label: "agy warm")
            return AntigravityWarmRules.sendOutcome(
                exitCode: result.exitCode,
                stdout: String(decoding: result.stdout, as: UTF8.self),
                stderr: result.stderr)
        } catch {
            return (false, "send_failed", AntigravitySubscriptionService.sanitizeForLog(error.localizedDescription))
        }
    }

    // MARK: Banner

    private func show(_ banner: Banner?) {
        self.banner = banner
        bannerTask?.cancel()
        guard banner != nil else { return }
        bannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }

    static func banner(for results: [AntigravityWarmResult]) -> Banner? {
        guard !results.isEmpty else { return nil }
        let started = results.filter { $0.outcome == "started" }
        if !started.isEmpty {
            let parts = started.map { result -> String in
                if let resets = result.resetsAt {
                    return L("%1$@ · resets %2$@", result.groupName, WindowWarmer.clockLabel(resets))
                }
                return result.groupName
            }
            return Banner(kind: .success, message: L("Window started: %@", parts.joined(separator: ", ")))
        }
        let first = results[0]
        return Banner(kind: .failure, message: reasonLabel(first, withGroup: results.count > 1))
    }

    static func reasonLabel(_ result: AntigravityWarmResult, withGroup: Bool = true) -> String {
        let text: String
        switch result.reason {
        case nil:
            if let resets = result.resetsAt {
                let start = resets.addingTimeInterval(-Double(WarmSchedulePrefs.windowMinutes) * 60)
                text = "\(WindowWarmer.clockLabel(start)) – \(WindowWarmer.clockLabel(resets))"
            } else {
                text = L("Warm sent")
            }
        case "window_running":
            if let resets = result.resetsAt {
                text = L("A 5-hour window is already running, so nothing was sent. It resets at %@.", WindowWarmer.clockLabel(resets))
            } else {
                text = L("A 5-hour window is already running, so nothing was sent")
            }
        case "weekly_full": text = L("The weekly limit is used up, so nothing was sent")
        case "usage_unavailable":
            if let detail = result.detail { text = L("Couldn't read Antigravity quota (%@), so nothing was sent", detail) }
            else { text = L("Couldn't read Antigravity quota, so nothing was sent") }
        case "agy_not_found": text = L("The Antigravity CLI (agy) isn't installed on this Mac")
        case "signed_out": text = L("agy is signed out. Run `agy` once and sign in.")
        case "no_model": text = L("agy lists no model in this group")
        case "no_window_yet": text = L("Warm sent; the new window isn't showing yet")
        default: text = L("agy didn't answer: %@", result.detail ?? L("no output"))
        }
        return withGroup ? "\(result.groupName): \(text)" : text
    }

#if DEBUG
    func seedForPreview(prefs: AntigravityWarmPrefs, history: [AntigravityWarmResult] = [], agyPath: String? = "/usr/local/bin/agy") {
        self.prefs = prefs
        self.history = history
        self.agyPath = agyPath
    }
#endif
}
