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
        #expect(wire == WarmWireSchedule(enabled: true, times: ["07:00", "12:00"], days: [0, 6], timeZone: "Europe/Istanbul"))
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

    @Test("A failed paired warm offers this Mac; a running window does not")
    @MainActor
    func banners() {
        let runner = WarmRunner(id: "ab", name: "vm", isLocal: false, state: "ok", status: nil)
        let failed = WarmNowResponse(state: "ok", result: WarmResultDTO(at: Date(), trigger: "manual", outcome: "failed", reason: "send_failed", detail: "Not logged in", resetsAt: nil, slot: nil))
        let banner = WindowWarmer.banner(for: failed, runner: runner, localAvailable: true)
        #expect(banner.kind == .failure)
        #expect(banner.offerLocal)
        #expect(banner.message.contains("Not logged in"))
        let running = WarmNowResponse(state: "ok", result: WarmResultDTO(at: Date(), trigger: "manual", outcome: "skipped", reason: "window_running", detail: nil, resetsAt: nil, slot: nil))
        #expect(!WindowWarmer.banner(for: running, runner: runner, localAvailable: true).offerLocal)
    }
}
