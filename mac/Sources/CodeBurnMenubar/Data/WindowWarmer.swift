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
    /// `WarmRunner.localId`, a paired device's fingerprint, or nil for the
    /// default (the first device that accepts warms, else this Mac).
    var runnerId: String?

    static let maxTimes = 4
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

    func wire(timeZone: TimeZone = .current) -> WarmWireSchedule {
        WarmWireSchedule(enabled: enabled, times: sortedTimes.map(Self.clock), days: days.sorted(), timeZone: timeZone.identifier)
    }
}

/// The schedule as the CLI and the runner store it.
struct WarmWireSchedule: Codable, Equatable, Sendable {
    let enabled: Bool
    let times: [String]
    let days: [Int]
    let timeZone: String
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
        /// Offer "Warm on this Mac" after a paired device failed.
        let offerLocal: Bool
        let id = UUID()
    }

    private(set) var prefs: WarmSchedulePrefs
    private(set) var report: WarmStatusReport?
    private(set) var isWarming = false
    private(set) var banner: Banner?
    /// A device the latest schedule could not be pushed to; retried on each
    /// status refresh.
    private(set) var unsyncedDeviceName: String?

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

    var runners: [WarmRunner] {
        guard let report else { return [] }
        var list: [WarmRunner] = []
        if report.local.claudeFound {
            list.append(WarmRunner(id: WarmRunner.localId, name: L("This Mac"), isLocal: true, state: "ok", status: report.local))
        }
        for device in report.devices where device.state != "unsupported" {
            list.append(WarmRunner(id: device.id, name: device.name, isLocal: false, state: device.state, status: device.status))
        }
        return list
    }

    var selectedRunner: WarmRunner? {
        let all = runners
        if let id = prefs.runnerId, let chosen = all.first(where: { $0.id == id }) { return chosen }
        return all.first(where: { !$0.isLocal && $0.usable }) ?? all.first(where: \.isLocal)
    }

    /// Whether the Warm button has anything to warm with.
    var canWarm: Bool { selectedRunner?.usable == true }

    var history: [WarmResultDTO] { selectedRunner?.status?.history ?? [] }

    func nextWarm(after now: Date = Date()) -> Date? {
        prefs.nextWarm(after: now)
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
            unsyncedDeviceName = nil
            return
        }
        do {
            let state = try await Self.push(prefs.wire(), to: runner.id)
            if state == "ok" {
                defaults.set(runner.id, forKey: Self.pushedRunnerKey)
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
        if let runner = selectedRunner, !runner.isLocal, runner.state == "ok",
           runner.status?.schedule != prefs.wire() || unsyncedDeviceName != nil {
            schedulePush()
        }
    }

    // MARK: Warm now

    func warmNow(onThisMac: Bool = false) async {
        guard !isWarming, !isPreview else { return }
        let runner = onThisMac ? runners.first(where: \.isLocal) : selectedRunner
        guard let runner, runner.usable else { return }
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
            newBanner = Self.banner(for: answer, runner: runner, localAvailable: runners.contains(where: \.isLocal))
        } catch {
            newBanner = Banner(kind: .failure, message: L("Couldn't warm on %1$@: %2$@", runner.name, L("CodeBurn could not run the warm")), offerLocal: false)
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

    static func banner(for answer: WarmNowResponse, runner: WarmRunner, localAvailable: Bool) -> Banner {
        let offerLocal = !runner.isLocal && localAvailable
        guard let result = answer.result else {
            let message = answer.state == "not_allowed"
                ? L("%@ doesn't accept warm requests. Start its share with --allow-warm.", runner.name)
                : L("Couldn't reach %@", runner.name)
            return Banner(kind: .failure, message: message, offerLocal: offerLocal)
        }
        switch (result.outcome, result.reason) {
        case ("started", nil):
            if let resets = result.resetsAt {
                return Banner(kind: .success, message: L("Window started on %1$@ · resets %2$@", runner.name, clockLabel(resets)), offerLocal: false)
            }
            return Banner(kind: .success, message: L("Warm sent on %@", runner.name), offerLocal: false)
        case ("started", _):
            return Banner(kind: .success, message: L("Warm sent on %@. The new window isn't showing yet.", runner.name), offerLocal: false)
        case (_, "window_running"):
            return Banner(kind: .failure, message: L("A 5-hour window is already running, so nothing was sent"), offerLocal: false)
        case (_, "weekly_full"):
            return Banner(kind: .failure, message: L("The weekly limit is used up, so nothing was sent"), offerLocal: false)
        case (_, "usage_unavailable"):
            return Banner(kind: .failure, message: L("Couldn't read Claude usage on %@, so nothing was sent", runner.name), offerLocal: offerLocal)
        case (_, "claude_not_found"):
            return Banner(kind: .failure, message: L("Couldn't warm on %1$@: %2$@", runner.name, L("Claude Code isn't installed there")), offerLocal: offerLocal)
        default:
            return Banner(kind: .failure, message: L("Couldn't warm on %1$@: %2$@", runner.name, result.detail ?? L("Claude Code didn't answer")), offerLocal: offerLocal)
        }
    }

    // MARK: This Mac's schedule

    /// Runs the schedule when this Mac is the runner. Only while the Mac is
    /// awake; a warm missed during sleep runs on wake within 30 minutes.
    func localTick(now: Date = Date()) async {
        guard prefs.enabled, let store else { return }
        let isLocalRunner = selectedRunner?.isLocal ?? (prefs.runnerId == WarmRunner.localId)
        guard isLocalRunner, let slot = prefs.dueSlot(at: now) else { return }
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
