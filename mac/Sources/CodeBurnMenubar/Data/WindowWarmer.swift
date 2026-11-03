import AppKit
import Foundation
import Observation

// The Claude window warmer: start a Claude 5-hour window at chosen times, or on
// demand, with one short message sent by the user's own signed-in Claude Code on
// the runner (`codeburn warm`). See docs/design/claude-window-warmer.md.

// MARK: - Schedule

/// The user's warm schedule. Times are local to this Mac; the runner gets them
/// with this Mac's time zone.
struct WarmSchedulePrefs: Codable, Equatable, Sendable {
    var enabled: Bool = false
    /// Minutes after local midnight, on 10-minute marks, unique. Kept in the
    /// order shown (an edit does not move a row under the cursor); use
    /// `sortedTimes` for anything that depends on order.
    var times: [Int] = []
    /// 0 = Monday … 6 = Sunday.
    var days: Set<Int> = Set(0...6)
    /// A paired device's fingerprint, or nil for the default (the first device
    /// that accepts warms). This Mac only runs warms when no device can.
    var runnerId: String?
    /// Warm again right after each reset (on the paired device only).
    var autoEnabled: Bool = false

    static let maxTimes = 4
    /// Auto-warm's active hours: a reset at or after 07:00 and before 24:00.
    static let autoHours = (7 * 60)..<(24 * 60)
    /// The window that just ended must have read above this percent.
    static let autoMinPercent = 2.0
    /// Warms (scheduled + auto) that may start a window per day.
    static let autoDailyCap = 5
    static let windowMinutes = 5 * 60
    static let lastMark = 23 * 60 + 50
    static let peakHours = (15 * 60)..<(21 * 60)

    static func snap(_ minutes: Int) -> Int {
        min(max(0, Int((Double(minutes) / 10).rounded()) * 10), lastMark)
    }

    /// Where "Add time" puts the next row: when the last window would end, or
    /// 07:00 for the first. Moves on by 10 minutes past a time already taken.
    var sortedTimes: [Int] { times.sorted() }

    var nextTimeToAdd: Int {
        var candidate = sortedTimes.last.map { ($0 + Self.windowMinutes) % (24 * 60) } ?? 7 * 60
        candidate = Self.snap(candidate)
        while times.contains(candidate) { candidate = (candidate + 10) % (24 * 60) }
        return candidate
    }

    var canAddTime: Bool { times.count < Self.maxTimes }

    mutating func addTime() {
        guard canAddTime else { return }
        times = (times + [nextTimeToAdd]).sorted()
    }

    mutating func removeTime(_ time: Int) {
        times.removeAll { $0 == time }
    }

    /// Moves `old` to `new` (snapped) in place; a move onto a time already
    /// listed just drops the old row.
    mutating func moveTime(_ old: Int, to new: Int) {
        let snapped = Self.snap(new)
        guard let index = times.firstIndex(of: old), snapped != old else { return }
        if times.contains(snapped) {
            times.remove(at: index)
        } else {
            times[index] = snapped
        }
    }

    /// The earlier scheduled time whose window `time` falls inside, if any.
    func overlappedTime(for time: Int) -> Int? {
        let sorted = sortedTimes
        guard let index = sorted.firstIndex(of: time), index > 0 else { return nil }
        let previous = sorted[index - 1]
        return time - previous < Self.windowMinutes ? previous : nil
    }

    static func weekdayIndex(of date: Date, calendar: Calendar) -> Int {
        // Calendar weekday: 1 = Sunday … 7 = Saturday.
        (calendar.component(.weekday, from: date) + 5) % 7
    }

    /// The next scheduled warm after `now`, within a week.
    func nextWarm(after now: Date, calendar: Calendar = .current) -> Date? {
        guard enabled, !times.isEmpty, !days.isEmpty else { return nil }
        let startOfToday = calendar.startOfDay(for: now)
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startOfToday),
                  days.contains(Self.weekdayIndex(of: day, calendar: calendar)) else { continue }
            for time in sortedTimes {
                guard let at = calendar.date(byAdding: .minute, value: time, to: day) else { continue }
                if at > now { return at }
            }
        }
        return nil
    }

    /// The slot due at `now` for a warm run by this Mac: a time on an enabled
    /// day that passed less than `graceMinutes` ago (a Mac asleep at the time
    /// catches up on wake within the grace).
    func dueSlot(at now: Date, graceMinutes: Int = 30, calendar: Calendar = .current) -> String? {
        guard enabled else { return nil }
        let day = calendar.startOfDay(for: now)
        guard days.contains(Self.weekdayIndex(of: day, calendar: calendar)) else { return nil }
        let minutes = Int(now.timeIntervalSince(day) / 60)
        guard let time = sortedTimes.last(where: { minutes >= $0 && minutes < $0 + graceMinutes }) else { return nil }
        let ymd = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d %@", ymd.year ?? 0, ymd.month ?? 0, ymd.day ?? 0, Self.clock(time))
    }

    static func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d", (minutes / 60) % 24, minutes % 60)
    }

    /// `includeAuto: false` is the schedule as a version-1 runner, which has no
    /// auto-warm, stores and reports it.
    func wire(timeZone: TimeZone = .current, includeAuto: Bool = true) -> WarmWireSchedule {
        WarmWireSchedule(
            enabled: enabled, times: sortedTimes.map(Self.clock), days: days.sorted(), timeZone: timeZone.identifier,
            auto: includeAuto ? WarmAutoWire(enabled: autoEnabled, from: Self.clock(Self.autoHours.lowerBound), to: "24:00") : nil
        )
    }

    /// When the running window's reset will be auto-warmed, if every rule but
    /// the idle check holds now: auto-warm on, the reset inside the active
    /// hours, the window read above 2%, and fewer than five automatic starts
    /// today. `percent` is 0–100.
    func autoWarmAt(resetsAt: Date?, percent: Double?, history: [WarmResultDTO], now: Date, calendar: Calendar = .current) -> Date? {
        guard autoEnabled, let resetsAt, resetsAt > now, let percent, percent > Self.autoMinPercent else { return nil }
        let minutes = Int(resetsAt.timeIntervalSince(calendar.startOfDay(for: resetsAt)) / 60)
        guard Self.autoHours.contains(minutes) else { return nil }
        let startsToday = history.filter {
            $0.trigger != "manual" && $0.outcome == "started" && calendar.isDate($0.at, inSameDayAs: now)
        }.count
        return startsToday < Self.autoDailyCap ? resetsAt : nil
    }
}

extension WarmSchedulePrefs {
    /// Prefs saved before a field existed decode with its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = WarmSchedulePrefs()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        times = try c.decodeIfPresent([Int].self, forKey: .times) ?? defaults.times
        days = try c.decodeIfPresent(Set<Int>.self, forKey: .days) ?? defaults.days
        runnerId = try c.decodeIfPresent(String.self, forKey: .runnerId)
        autoEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoEnabled) ?? defaults.autoEnabled
    }
}

/// The schedule as the CLI and the runner store it.
struct WarmWireSchedule: Codable, Equatable, Sendable {
    let enabled: Bool
    let times: [String]
    let days: [Int]
    let timeZone: String
    /// Absent from version-1 runners.
    var auto: WarmAutoWire? = nil
}

struct WarmAutoWire: Codable, Equatable, Sendable {
    let enabled: Bool
    let from: String
    let to: String
}

// MARK: - CLI answers

struct WarmResultDTO: Decodable, Equatable, Sendable, Identifiable {
    let at: Date
    let trigger: String
    let outcome: String
    let reason: String?
    let detail: String?
    let resetsAt: Date?
    let slot: String?
    var id: Date { at }
}

struct WarmStatusDTO: Decodable, Equatable, Sendable {
    /// 2 and up has auto-warm.
    let version: Int?
    let allowed: Bool
    let claudeFound: Bool
    let signedIn: Bool?
    let warming: Bool
    let schedule: WarmWireSchedule?
    let history: [WarmResultDTO]
}

struct WarmDeviceDTO: Decodable, Equatable, Sendable {
    let id: String
    let name: String
    let state: String
    let status: WarmStatusDTO?
}

struct WarmStatusReport: Decodable, Equatable, Sendable {
    let local: WarmStatusDTO
    let devices: [WarmDeviceDTO]
}

struct WarmNowResponse: Decodable, Sendable {
    let state: String
    let result: WarmResultDTO?
}

enum WarmJSON {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(raw)"))
        }
        return decoder
    }
}

// MARK: - Runner

struct WarmRunner: Identifiable, Equatable, Sendable {
    static let localId = "local"

    let id: String
    let name: String
    let isLocal: Bool
    /// The device's answer: ok, not_allowed, unsupported, unauthorized, unreachable.
    let state: String
    let status: WarmStatusDTO?

    var usable: Bool { isLocal || state == "ok" }
    /// Auto-warm runs only on a paired device new enough to have it.
    var supportsAuto: Bool { !isLocal && (status?.version ?? 1) >= 2 }
}

// MARK: - Service

@MainActor
@Observable
final class WindowWarmer {
    static let shared = WindowWarmer()

    struct Banner: Equatable {
        enum Kind { case success, failure }
        let kind: Kind
        let message: String
        let id = UUID()
    }

    private(set) var prefs: WarmSchedulePrefs
    private(set) var report: WarmStatusReport?
    private(set) var isWarming = false
    private(set) var banner: Banner?
    /// A device the latest schedule could not be pushed to; retried on each
    /// status refresh.
    private(set) var unsyncedDeviceName: String?
    /// The device the schedule was last pushed to. It stays the runner while
    /// it is briefly unreachable, so the schedule never falls back to this Mac.
    private(set) var pushedRunnerId: String?

    @ObservationIgnored weak var store: AppStore?
    @ObservationIgnored private var statusFetchedAt: Date?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var started = false
    /// Set by `seedForPreview`: never touch the CLI or a device.
    @ObservationIgnored private var isPreview = false

    private static let prefsKey = "claudeWindowWarmer.prefs"
    private static let pushedRunnerKey = "claudeWindowWarmer.pushedRunner"
    private static let lastLocalSlotKey = "claudeWindowWarmer.lastLocalSlot"

    init(defaults: UserDefaults = .standard) {
        if let data = defaults.data(forKey: Self.prefsKey),
           let saved = try? JSONDecoder().decode(WarmSchedulePrefs.self, from: data) {
            prefs = saved
        } else {
            prefs = WarmSchedulePrefs()
        }
        pushedRunnerId = defaults.string(forKey: Self.pushedRunnerKey)
    }

#if DEBUG
    /// Previews and snapshot tests: state without the CLI, persistence or a push.
    func seedForPreview(prefs: WarmSchedulePrefs, report: WarmStatusReport?, banner: Banner? = nil, isWarming: Bool = false) {
        self.prefs = prefs
        self.report = report
        self.banner = banner
        self.isWarming = isWarming
        isPreview = true
    }
#endif

    // MARK: Runners

    /// Every warm, scheduled, automatic or from the button, runs on a paired
    /// device, so it works while this Mac sleeps. A device counts once it
    /// accepts warms, or once it has been chosen or used, so a moment offline
    /// does not hand the job to this Mac. This Mac runs warms only when no
    /// device does; failing that, devices that still need `--allow-warm` are
    /// listed so the status line can say so.
    var runners: [WarmRunner] {
        guard let report else { return [] }
        let devices = report.devices.filter { $0.state != "unsupported" }.map {
            WarmRunner(id: $0.id, name: $0.name, isLocal: false, state: $0.state, status: $0.status)
        }
        let warming = devices.filter { $0.state == "ok" || $0.id == prefs.runnerId || $0.id == pushedRunnerId }
        if !warming.isEmpty { return warming }
        if report.local.claudeFound {
            return [WarmRunner(id: WarmRunner.localId, name: L("This Mac"), isLocal: true, state: "ok", status: report.local)]
        }
        return devices
    }

    var selectedRunner: WarmRunner? {
        let all = runners
        if let id = prefs.runnerId, let chosen = all.first(where: { $0.id == id }) { return chosen }
        return all.first(where: \.usable) ?? all.first
    }

    /// Whether the Warm button has anything to warm with.
    var canWarm: Bool { selectedRunner?.usable == true }

    var history: [WarmResultDTO] { selectedRunner?.status?.history ?? [] }

    func nextWarm(after now: Date = Date()) -> Date? {
        prefs.nextWarm(after: now)
    }

    /// "Auto-warm at 15:00" for the Plan header: the running window's reset,
    /// when the runner will warm right after it.
    func autoWarmAt(resetsAt: Date?, percent: Double?, now: Date = Date()) -> Date? {
        guard let runner = selectedRunner, runner.supportsAuto, runner.state == "ok" else { return nil }
        return prefs.autoWarmAt(resetsAt: resetsAt, percent: percent, history: history, now: now)
    }

    // MARK: Lifecycle

    func start(store: AppStore) {
        self.store = store
        guard !started else { return }
        started = true
        let timer = Timer(timeInterval: 60, repeats: true) { _ in
            Task { @MainActor in await WindowWarmer.shared.localTick() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await WindowWarmer.shared.localTick() }
        }
        NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in WindowWarmer.shared.schedulePush() }
        }
        Task { await refreshStatus(force: true) }
    }

    // MARK: Settings

    func update(_ change: (inout WarmSchedulePrefs) -> Void) {
        var next = prefs
        change(&next)
        guard next != prefs else { return }
        prefs = next
        if let data = try? JSONEncoder().encode(next) {
            UserDefaults.standard.set(data, forKey: Self.prefsKey)
        }
        schedulePush()
    }

    func schedulePush() {
        guard !isPreview else { return }
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await self?.pushSchedule()
        }
    }

    /// Sends the schedule to the selected device, and turns it off on the
    /// device that ran it before, so only one runner ever holds an enabled
    /// schedule. This Mac runs its own schedule in `localTick`.
    private func pushSchedule() async {
        guard let runner = selectedRunner else { return }
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: Self.pushedRunnerKey)
        if let previous, previous != runner.id, previous != WarmRunner.localId {
            var off = prefs
            off.enabled = false
            _ = try? await Self.push(off.wire(), to: previous)
        }
        if runner.isLocal {
            defaults.set(runner.id, forKey: Self.pushedRunnerKey)
            pushedRunnerId = runner.id
            unsyncedDeviceName = nil
            return
        }
        do {
            let state = try await Self.push(prefs.wire(), to: runner.id)
            if state == "ok" {
                defaults.set(runner.id, forKey: Self.pushedRunnerKey)
                pushedRunnerId = runner.id
                unsyncedDeviceName = nil
            } else {
                unsyncedDeviceName = runner.name
            }
        } catch {
            unsyncedDeviceName = runner.name
        }
        await refreshStatus(force: true)
    }

    private static func push(_ schedule: WarmWireSchedule, to deviceId: String) async throws -> String {
        let json = String(decoding: try JSONEncoder().encode(schedule), as: UTF8.self)
        let data = try await DataClient.runWarmCommand(["warm", "schedule", "--device", deviceId, "--set", json, "--format", "json"])
        struct Answer: Decodable { let state: String }
        return try JSONDecoder().decode(Answer.self, from: data).state
    }

    // MARK: Status

    /// Reads this Mac's and every paired device's warm status, at most once a
    /// minute unless forced, then re-pushes the schedule if the runner lost it.
    func refreshStatus(force: Bool = false) async {
        guard !isPreview else { return }
        if !force, let at = statusFetchedAt, Date().timeIntervalSince(at) < 60 { return }
        if let statusTask { await statusTask.value; return }
        let task = Task { @MainActor in
            do {
                let data = try await DataClient.runWarmCommand(["warm", "status", "--devices", "--format", "json"])
                report = try WarmJSON.decoder().decode(WarmStatusReport.self, from: data)
                statusFetchedAt = Date()
            } catch {
                NSLog("CodeBurn: warm status failed: %@", String(describing: error))
            }
        }
        statusTask = task
        await task.value
        statusTask = nil
        // A version-1 runner drops auto-warm, so compare without it there;
        // otherwise every refresh would push again.
        if let runner = selectedRunner, !runner.isLocal, runner.state == "ok",
           runner.status?.schedule != prefs.wire(includeAuto: runner.supportsAuto) || unsyncedDeviceName != nil {
            schedulePush()
        }
    }

    // MARK: Warm now

    /// Warms on the runner: the paired device whenever there is one.
    func warmNow() async {
        guard !isWarming, !isPreview else { return }
        guard let runner = selectedRunner, runner.usable else { return }
        isWarming = true
        banner = nil
        defer { isWarming = false }
        let args = runner.isLocal
            // The app only offers Warm when its own reading says no window is
            // running, so the local CLI skips a second (keychain) read.
            ? ["warm", "--force", "--format", "json"]
            : ["warm", "--device", runner.id, "--format", "json"]
        var newBanner: Banner
        do {
            let data = try await DataClient.runWarmCommand(args)
            let answer = try WarmJSON.decoder().decode(WarmNowResponse.self, from: data)
            newBanner = Self.banner(for: answer, runner: runner)
        } catch {
            newBanner = Banner(kind: .failure, message: L("Couldn't warm on %1$@: %2$@", runner.name, L("CodeBurn could not run the warm")))
        }
        show(newBanner)
        await store?.refreshSubscription()
        await refreshStatus(force: true)
    }

    private func show(_ banner: Banner) {
        self.banner = banner
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }

    static func clockLabel(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func banner(for answer: WarmNowResponse, runner: WarmRunner) -> Banner {
        guard let result = answer.result else {
            let message = answer.state == "not_allowed"
                ? L("%@ doesn't accept warm requests. Start its share with --allow-warm.", runner.name)
                : L("Couldn't reach %@", runner.name)
            return Banner(kind: .failure, message: message)
        }
        switch (result.outcome, result.reason) {
        case ("started", nil):
            if let resets = result.resetsAt {
                return Banner(kind: .success, message: L("Window started on %1$@ · resets %2$@", runner.name, clockLabel(resets)))
            }
            return Banner(kind: .success, message: L("Warm sent on %@", runner.name))
        case ("started", _):
            return Banner(kind: .success, message: L("Warm sent on %@. The new window isn't showing yet.", runner.name))
        case (_, "window_running"):
            return Banner(kind: .failure, message: L("A 5-hour window is already running, so nothing was sent"))
        case (_, "weekly_full"):
            return Banner(kind: .failure, message: L("The weekly limit is used up, so nothing was sent"))
        case (_, "signed_out"):
            return Banner(kind: .failure, message: L("Claude Code is signed out on %@. Run `claude` there and sign in with /login.", runner.name))
        case (_, "usage_unavailable"):
            if let detail = result.detail {
                return Banner(kind: .failure, message: L("Couldn't read Claude usage on %1$@ (%2$@), so nothing was sent", runner.name, detail))
            }
            return Banner(kind: .failure, message: L("Couldn't read Claude usage on %@, so nothing was sent", runner.name))
        case (_, "claude_not_found"):
            return Banner(kind: .failure, message: L("Couldn't warm on %1$@: %2$@", runner.name, L("Claude Code isn't installed there")))
        default:
            return Banner(kind: .failure, message: L("Couldn't warm on %1$@: %2$@", runner.name, result.detail ?? L("Claude Code didn't answer")))
        }
    }

    // MARK: This Mac's schedule

    /// Runs the schedule when this Mac is the runner. Only while the Mac is
    /// awake; a warm missed during sleep runs on wake within 30 minutes.
    func localTick(now: Date = Date()) async {
        guard prefs.enabled, let store else { return }
        // Only when the status is loaded and names this Mac: before that a
        // paired device may well be the runner.
        guard selectedRunner?.isLocal == true, let slot = prefs.dueSlot(at: now) else { return }
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: Self.lastLocalSlotKey) != slot else { return }
        defaults.set(slot, forKey: Self.lastLocalSlotKey)
        await store.refreshSubscription()
        guard let usage = store.subscription, let percent = usage.fiveHourPercent,
              usage.fiveHourResetsAt == nil, percent <= 0 else { return }
        _ = try? await DataClient.runWarmCommand(["warm", "--force", "--scheduled", "--format", "json"])
        await store.refreshSubscription()
        await refreshStatus(force: true)
    }
}
