import Foundation
import Testing
@testable import CodeBurnMenubar

@Suite("Claude window warmer schedule")
struct WindowWarmerTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        return calendar
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    @Test("Add time starts at 07:00, then follows the previous window, up to four")
    func addTime() {
        var prefs = WarmSchedulePrefs()
        prefs.addTime()
        prefs.addTime()
        prefs.addTime()
        #expect(prefs.times == [7 * 60, 12 * 60, 17 * 60])
        prefs.addTime()
        #expect(prefs.times == [7 * 60, 12 * 60, 17 * 60, 22 * 60])
        #expect(!prefs.canAddTime)
        prefs.addTime()
        #expect(prefs.times.count == 4)
    }

    @Test("Editing a time snaps it and keeps its row; a duplicate drops the row")
    func moveTime() {
        var prefs = WarmSchedulePrefs(enabled: true, times: [12 * 60, 7 * 60])
        prefs.moveTime(12 * 60, to: 13 * 60 + 4)
        #expect(prefs.times == [13 * 60, 7 * 60])
        prefs.moveTime(13 * 60, to: 7 * 60 + 2)
        #expect(prefs.times == [7 * 60])
    }

    @Test("A time inside the previous window is flagged")
    func overlap() {
        let prefs = WarmSchedulePrefs(enabled: true, times: [7 * 60, 10 * 60, 17 * 60])
        #expect(prefs.overlappedTime(for: 10 * 60) == 7 * 60)
        #expect(prefs.overlappedTime(for: 17 * 60) == nil)
        #expect(prefs.overlappedTime(for: 7 * 60) == nil)
    }

    @Test("Next warm skips disabled days and wraps to the next enabled one")
    func nextWarm() {
        // 2026-10-31 is a Saturday (index 5).
        let prefs = WarmSchedulePrefs(enabled: true, times: [7 * 60, 12 * 60], days: Set(0...4))
        #expect(prefs.nextWarm(after: date(2026, 10, 31, 14, 0), calendar: calendar) == date(2026, 11, 2, 7, 0))
        let everyDay = WarmSchedulePrefs(enabled: true, times: [7 * 60, 12 * 60])
        #expect(everyDay.nextWarm(after: date(2026, 10, 31, 8, 0), calendar: calendar) == date(2026, 10, 31, 12, 0))
        #expect(WarmSchedulePrefs(enabled: false, times: [7 * 60]).nextWarm(after: Date(), calendar: calendar) == nil)
    }

    @Test("This Mac fires a slot within 30 minutes of its time")
    func dueSlot() {
        let prefs = WarmSchedulePrefs(enabled: true, times: [7 * 60])
        #expect(prefs.dueSlot(at: date(2026, 10, 31, 7, 29), calendar: calendar) == "2026-10-31 07:00")
        #expect(prefs.dueSlot(at: date(2026, 10, 31, 7, 30), calendar: calendar) == nil)
        #expect(prefs.dueSlot(at: date(2026, 10, 31, 6, 59), calendar: calendar) == nil)
    }

    @Test("The runner gets sorted HH:MM times, Monday-first days and this Mac's zone")
    func wire() {
        let prefs = WarmSchedulePrefs(enabled: true, times: [12 * 60, 7 * 60], days: [6, 0])
        let wire = prefs.wire(timeZone: TimeZone(identifier: "Europe/Istanbul")!)
        #expect(wire == WarmWireSchedule(enabled: true, times: ["07:00", "12:00"], days: [0, 6], timeZone: "Europe/Istanbul",
                                         auto: WarmAutoWire(enabled: false, from: "07:00", to: "24:00")))
        // A version-1 runner reports the schedule without auto-warm.
        #expect(prefs.wire(timeZone: TimeZone(identifier: "Europe/Istanbul")!, includeAuto: false).auto == nil)
    }

    @Test("Prefs saved before auto-warm existed still load")
    func decodeOldPrefs() throws {
        let old = #"{"enabled":true,"times":[420],"days":[0,1],"runnerId":"ab"}"#
        let prefs = try JSONDecoder().decode(WarmSchedulePrefs.self, from: Data(old.utf8))
        #expect(prefs == WarmSchedulePrefs(enabled: true, times: [420], days: [0, 1], runnerId: "ab", autoEnabled: false))
    }

    private func started(_ at: Date, _ trigger: String) -> WarmResultDTO {
        WarmResultDTO(at: at, trigger: trigger, outcome: "started", reason: nil, detail: nil, resetsAt: nil, slot: nil)
    }

    @Test("The header shows auto-warm only when the runner will warm at this reset")
    func autoWarmAt() {
        let now = date(2026, 10, 31, 13, 0)
        let reset = date(2026, 10, 31, 15, 0)
        let on = WarmSchedulePrefs(autoEnabled: true)
        #expect(on.autoWarmAt(resetsAt: reset, percent: 30, history: [], now: now, calendar: calendar) == reset)
        #expect(WarmSchedulePrefs().autoWarmAt(resetsAt: reset, percent: 30, history: [], now: now, calendar: calendar) == nil)
        // Not used enough, or no window.
        #expect(on.autoWarmAt(resetsAt: reset, percent: 2, history: [], now: now, calendar: calendar) == nil)
        #expect(on.autoWarmAt(resetsAt: nil, percent: 30, history: [], now: now, calendar: calendar) == nil)
        // Outside 07:00–24:00.
        #expect(on.autoWarmAt(resetsAt: date(2026, 11, 1, 0, 0), percent: 30, history: [], now: date(2026, 10, 31, 22, 0), calendar: calendar) == nil)
        #expect(on.autoWarmAt(resetsAt: date(2026, 10, 31, 23, 50), percent: 30, history: [], now: date(2026, 10, 31, 22, 0), calendar: calendar) != nil)
        #expect(on.autoWarmAt(resetsAt: date(2026, 11, 1, 6, 50), percent: 30, history: [], now: date(2026, 11, 1, 5, 0), calendar: calendar) == nil)
        // Five automatic starts today reach the cap; manual ones do not count.
        let five = (1...5).map { started(date(2026, 10, 31, $0, 0), "auto") }
        #expect(on.autoWarmAt(resetsAt: reset, percent: 30, history: five, now: now, calendar: calendar) == nil)
        let manual = (1...5).map { started(date(2026, 10, 31, $0, 0), $0 == 1 ? "manual" : "scheduled") }
        #expect(on.autoWarmAt(resetsAt: reset, percent: 30, history: manual, now: now, calendar: calendar) == reset)
    }

    @Test("CLI answers decode, including fractional-second dates")
    func decode() throws {
        let json = """
        {"local":{"version":1,"allowed":true,"claudeFound":true,"signedIn":null,"warming":false,"timeZone":"Europe/Istanbul","schedule":null,"history":[]},
         "devices":[{"id":"ab","name":"vm","state":"ok","status":{"version":1,"allowed":true,"claudeFound":true,"signedIn":true,"warming":false,"timeZone":"UTC",
           "schedule":{"enabled":true,"times":["07:00"],"days":[0,1],"timeZone":"Europe/Istanbul"},
           "history":[{"at":"2026-10-31T04:00:12.345Z","trigger":"scheduled","outcome":"started","reason":null,"detail":null,"resetsAt":"2026-10-31T09:00:00.000Z","slot":"2026-10-31 07:00"}]}}]}
        """
        let report = try WarmJSON.decoder().decode(WarmStatusReport.self, from: Data(json.utf8))
        #expect(report.devices.first?.status?.history.first?.outcome == "started")
        #expect(report.devices.first?.status?.schedule?.times == ["07:00"])
    }

    @Test("A failed paired warm shows Claude Code's message")
    @MainActor
    func banners() {
        let runner = WarmRunner(id: "ab", name: "vm", isLocal: false, state: "ok", status: nil)
        let failed = WarmNowResponse(state: "ok", result: WarmResultDTO(at: Date(), trigger: "manual", outcome: "failed", reason: "send_failed", detail: "Not logged in", resetsAt: nil, slot: nil))
        let banner = WindowWarmer.banner(for: failed, runner: runner)
        #expect(banner.kind == .failure)
        #expect(banner.message.contains("Not logged in"))
    }

    private func status(version: Int) -> WarmStatusDTO {
        WarmStatusDTO(version: version, allowed: true, claudeFound: true, signedIn: true, warming: false, schedule: nil, history: [])
    }

    private func report(devices: [WarmDeviceDTO], localClaude: Bool = true) -> WarmStatusReport {
        WarmStatusReport(local: WarmStatusDTO(version: 2, allowed: true, claudeFound: localClaude, signedIn: nil, warming: false, schedule: nil, history: []), devices: devices)
    }

    @Test("Every warm runs on the paired device; this Mac only without one")
    @MainActor
    func runnerSelection() {
        let warmer = WindowWarmer(defaults: UserDefaults(suiteName: "warm-test-\(UUID())")!)
        let vm = WarmDeviceDTO(id: "vm", name: "vm", state: "ok", status: status(version: 2))
        warmer.seedForPreview(prefs: WarmSchedulePrefs(runnerId: WarmRunner.localId), report: report(devices: [vm]))
        #expect(warmer.runners.map(\.id) == ["vm"])
        #expect(warmer.selectedRunner?.id == "vm")
        #expect(warmer.selectedRunner?.supportsAuto == true)

        // The chosen device stays the runner while it is offline.
        let offline = WarmDeviceDTO(id: "vm", name: "vm", state: "unreachable", status: nil)
        warmer.seedForPreview(prefs: WarmSchedulePrefs(runnerId: "vm"), report: report(devices: [offline]))
        #expect(warmer.selectedRunner?.id == "vm")
        #expect(warmer.selectedRunner?.usable == false)

        // No device that warms: this Mac, which has no auto-warm.
        let other = WarmDeviceDTO(id: "mac2", name: "mac2", state: "not_allowed", status: nil)
        warmer.seedForPreview(prefs: WarmSchedulePrefs(), report: report(devices: [other]))
        #expect(warmer.selectedRunner?.isLocal == true)
        #expect(warmer.selectedRunner?.supportsAuto == false)

        // Without Claude Code here, the device that needs --allow-warm is shown.
        warmer.seedForPreview(prefs: WarmSchedulePrefs(), report: report(devices: [other], localClaude: false))
        #expect(warmer.selectedRunner?.id == "mac2")

        // A version-1 device runs warms but not auto-warm.
        let old = WarmDeviceDTO(id: "vm", name: "vm", state: "ok", status: status(version: 1))
        warmer.seedForPreview(prefs: WarmSchedulePrefs(autoEnabled: true), report: report(devices: [old]))
        #expect(warmer.selectedRunner?.supportsAuto == false)
        #expect(warmer.autoWarmAt(resetsAt: Date().addingTimeInterval(3600), percent: 50) == nil)
    }
}
