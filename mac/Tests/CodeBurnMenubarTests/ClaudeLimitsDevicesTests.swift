import Foundation
import SwiftUI
import Testing
import XCTest
@testable import CodeBurnMenubar

/// `codeburn limits` with a paired device: the output of the CLI's own math
/// for a Mac and a VM on one Claude account, plus a paired Mac on an older
/// CodeBurn. See docs/design/claude-session-usage.md, "Paired devices".
enum ClaudeLimitsDevicesFixture {
    static let json = #"""
{"generatedAt":"2026-10-18T05:10:00.000Z","plan":null,"readingsThrough":"2026-10-18T05:08:00.000Z","current":{"session":{"id":"2026-10-18T08:00:00.000Z","start":"2026-10-18T03:00:00.000Z","end":"2026-10-18T08:00:00.000Z","startInferred":false,"running":true,"spentUSD":41,"tokens":{"input":45,"output":900,"cacheRead":3900000,"cacheWrite":84000},"fiveHourPct":36,"fiveHourQuality":"measured","weekPct":3,"weekQuality":"measured","weekFrom":49,"weekTo":52,"fullSessionUSD":113.88888888888889,"fullSessionQuality":"lowerBound","outsideThisMac":false,"unpricedModels":[],"chats":[{"sessionId":"c1","title":"Paired devices spec for Claude sessions","spentUSD":18.4,"project":"codeburn","path":"/Users/me/codeburn","firstAt":"2026-10-18T03:12:00.000Z","lastAt":"2026-10-18T03:12:00.000Z","promptCount":0,"prompts":[]},{"sessionId":"device:fp-vm","title":"instance-20260829-212457","spentUSD":9.2,"device":{"id":"fp-vm","name":"instance-20260829-212457"},"firstAt":"2026-10-18T04:01:00.000Z","lastAt":"2026-10-18T05:01:00.000Z","promptCount":0,"prompts":[]},{"sessionId":"c2","title":"Install codeburn on the VM over Tailscale","spentUSD":9.1,"project":"codeburn","path":"/Users/me/codeburn","firstAt":"2026-10-18T04:20:00.000Z","lastAt":"2026-10-18T04:20:00.000Z","promptCount":0,"prompts":[]},{"sessionId":"c3","title":"Menubar week strip polish","spentUSD":4.3,"project":"codeburn","path":"/Users/me/codeburn","firstAt":"2026-10-18T03:30:00.000Z","lastAt":"2026-10-18T03:30:00.000Z","promptCount":0,"prompts":[]}],"models":[{"model":"Opus 5.5","spentUSD":41,"tokens":3984945,"peerSpentUSD":9.2}],"hours":[{"start":"2026-10-18T03:00:00.000Z","end":"2026-10-18T04:00:00.000Z","spentUSD":22.7,"tokens":1840420,"fiveHourPct":1},{"start":"2026-10-18T04:00:00.000Z","end":"2026-10-18T05:00:00.000Z","spentUSD":17.1,"tokens":1736420,"fiveHourPct":null,"peerSpentUSD":8},{"start":"2026-10-18T05:00:00.000Z","end":"2026-10-18T06:00:00.000Z","spentUSD":1.2,"tokens":408105,"fiveHourPct":36,"peerSpentUSD":1.2}],"devices":[{"id":"local","name":"Ege-MacBook-Pro.local","local":true,"spentUSD":31.799999999999997},{"id":"fp-vm","name":"instance-20260829-212457","local":false,"spentUSD":9.2}],"deviceNotes":[{"id":"fp-old","name":"old-studio","kind":"unsupported"}],"spentLowerBound":true},"week":{"start":"2026-10-17T08:00:00.000Z","end":"2026-10-24T08:00:00.000Z","endReason":"running","startInferred":false,"running":true,"spentUSD":63.6,"tokens":{"input":70,"output":1400,"cacheRead":6000000,"cacheWrite":128000},"usedPct":52,"usedQuality":"measured","fullWeekUSD":122.30769230769232,"fullWeekQuality":"lowerBound","unpricedModels":[],"models":[{"model":"Opus 5.5","spentUSD":63.6,"tokens":6129470,"peerSpentUSD":31.599999999999998}],"days":[{"start":"2026-10-17T08:00:00.000Z","end":"2026-10-18T08:00:00.000Z","spentUSD":63.6,"tokens":6129470,"usedPct":52,"peerSpentUSD":31.599999999999998}],"sessions":[{"id":"2026-10-17T20:40:00.000Z","start":"2026-10-17T15:40:00.000Z","end":"2026-10-17T20:40:00.000Z","running":false,"spentUSD":22.6,"weekPct":2,"weekQuality":"measured"},{"id":"2026-10-18T08:00:00.000Z","start":"2026-10-18T03:00:00.000Z","end":"2026-10-18T08:00:00.000Z","running":true,"spentUSD":41,"weekPct":3,"weekQuality":"measured"}],"devices":[{"id":"local","name":"Ege-MacBook-Pro.local","local":true,"spentUSD":32},{"id":"fp-vm","name":"instance-20260829-212457","local":false,"spentUSD":31.599999999999998}],"deviceNotes":[{"id":"fp-old","name":"old-studio","kind":"unsupported"}],"spentLowerBound":true,"previousAtSamePoint":{"at":"2026-10-11T05:10:00.000Z","spentUSD":0,"usedPct":null,"usedQuality":"unknown"}}},"rate":{"weekPerSessionPoint":null,"basis":0,"restartedAt":null},"sessionsLeft":null,"runsOutFirstAtSessionPct":null,"fullWeekAverage":{"usd":null,"basis":0},"sessions":[{"id":"2026-10-18T08:00:00.000Z","start":"2026-10-18T03:00:00.000Z","end":"2026-10-18T08:00:00.000Z","startInferred":false,"running":true,"spentUSD":41,"tokens":{"input":45,"output":900,"cacheRead":3900000,"cacheWrite":84000},"fiveHourPct":36,"fiveHourQuality":"measured","weekPct":3,"weekQuality":"measured","weekFrom":49,"weekTo":52,"fullSessionUSD":113.88888888888889,"fullSessionQuality":"lowerBound","outsideThisMac":false,"unpricedModels":[],"chats":[{"sessionId":"c1","title":"Paired devices spec for Claude sessions","spentUSD":18.4,"project":"codeburn","path":"/Users/me/codeburn","firstAt":"2026-10-18T03:12:00.000Z","lastAt":"2026-10-18T03:12:00.000Z","promptCount":0,"prompts":[]},{"sessionId":"device:fp-vm","title":"instance-20260829-212457","spentUSD":9.2,"device":{"id":"fp-vm","name":"instance-20260829-212457"},"firstAt":"2026-10-18T04:01:00.000Z","lastAt":"2026-10-18T05:01:00.000Z","promptCount":0,"prompts":[]},{"sessionId":"c2","title":"Install codeburn on the VM over Tailscale","spentUSD":9.1,"project":"codeburn","path":"/Users/me/codeburn","firstAt":"2026-10-18T04:20:00.000Z","lastAt":"2026-10-18T04:20:00.000Z","promptCount":0,"prompts":[]},{"sessionId":"c3","title":"Menubar week strip polish","spentUSD":4.3,"project":"codeburn","path":"/Users/me/codeburn","firstAt":"2026-10-18T03:30:00.000Z","lastAt":"2026-10-18T03:30:00.000Z","promptCount":0,"prompts":[]}],"models":[{"model":"Opus 5.5","spentUSD":41,"tokens":3984945,"peerSpentUSD":9.2}],"hours":[{"start":"2026-10-18T03:00:00.000Z","end":"2026-10-18T04:00:00.000Z","spentUSD":22.7,"tokens":1840420,"fiveHourPct":1},{"start":"2026-10-18T04:00:00.000Z","end":"2026-10-18T05:00:00.000Z","spentUSD":17.1,"tokens":1736420,"fiveHourPct":null,"peerSpentUSD":8},{"start":"2026-10-18T05:00:00.000Z","end":"2026-10-18T06:00:00.000Z","spentUSD":1.2,"tokens":408105,"fiveHourPct":36,"peerSpentUSD":1.2}],"devices":[{"id":"local","name":"Ege-MacBook-Pro.local","local":true,"spentUSD":31.799999999999997},{"id":"fp-vm","name":"instance-20260829-212457","local":false,"spentUSD":9.2}],"deviceNotes":[{"id":"fp-old","name":"old-studio","kind":"unsupported"}],"spentLowerBound":true},{"id":"2026-10-17T20:40:00.000Z","start":"2026-10-17T15:40:00.000Z","end":"2026-10-17T20:40:00.000Z","startInferred":false,"running":false,"spentUSD":22.6,"tokens":{"input":25,"output":500,"cacheRead":2100000,"cacheWrite":44000},"fiveHourPct":24,"fiveHourQuality":"measured","weekPct":2,"weekQuality":"measured","weekFrom":30,"weekTo":32,"fullSessionUSD":94.16666666666667,"fullSessionQuality":"estimated","outsideThisMac":false,"unpricedModels":[],"chats":[{"sessionId":"device:fp-vm","title":"instance-20260829-212457","spentUSD":22.4,"device":{"id":"fp-vm","name":"instance-20260829-212457"},"firstAt":"2026-10-17T16:00:00.000Z","lastAt":"2026-10-17T19:19:00.000Z","promptCount":0,"prompts":[]},{"sessionId":"c4","title":"Quick question","spentUSD":0.2,"project":"codeburn","path":"/Users/me/codeburn","firstAt":"2026-10-17T15:50:00.000Z","lastAt":"2026-10-17T15:50:00.000Z","promptCount":0,"prompts":[]}],"models":[{"model":"Opus 5.5","spentUSD":22.6,"tokens":2144525,"peerSpentUSD":22.4}],"hours":[{"start":"2026-10-17T15:40:00.000Z","end":"2026-10-17T16:40:00.000Z","spentUSD":6.3,"tokens":1328315,"fiveHourPct":0,"peerSpentUSD":6.1},{"start":"2026-10-17T16:40:00.000Z","end":"2026-10-17T17:40:00.000Z","spentUSD":7.4,"tokens":408105,"fiveHourPct":null,"peerSpentUSD":7.4},{"start":"2026-10-17T17:40:00.000Z","end":"2026-10-17T18:40:00.000Z","spentUSD":0,"tokens":0,"fiveHourPct":null},{"start":"2026-10-17T18:40:00.000Z","end":"2026-10-17T19:40:00.000Z","spentUSD":8.9,"tokens":408105,"fiveHourPct":null,"peerSpentUSD":8.9},{"start":"2026-10-17T19:40:00.000Z","end":"2026-10-17T20:40:00.000Z","spentUSD":0,"tokens":0,"fiveHourPct":24}],"devices":[{"id":"local","name":"Ege-MacBook-Pro.local","local":true,"spentUSD":0.2},{"id":"fp-vm","name":"instance-20260829-212457","local":false,"spentUSD":22.4}]}],"weeks":[{"start":"2026-10-17T08:00:00.000Z","end":"2026-10-24T08:00:00.000Z","endReason":"running","startInferred":false,"running":true,"spentUSD":63.6,"tokens":{"input":70,"output":1400,"cacheRead":6000000,"cacheWrite":128000},"usedPct":52,"usedQuality":"measured","fullWeekUSD":122.30769230769232,"fullWeekQuality":"lowerBound","unpricedModels":[],"models":[{"model":"Opus 5.5","spentUSD":63.6,"tokens":6129470,"peerSpentUSD":31.599999999999998}],"days":[{"start":"2026-10-17T08:00:00.000Z","end":"2026-10-18T08:00:00.000Z","spentUSD":63.6,"tokens":6129470,"usedPct":52,"peerSpentUSD":31.599999999999998}],"sessions":[{"id":"2026-10-17T20:40:00.000Z","start":"2026-10-17T15:40:00.000Z","end":"2026-10-17T20:40:00.000Z","running":false,"spentUSD":22.6,"weekPct":2,"weekQuality":"measured"},{"id":"2026-10-18T08:00:00.000Z","start":"2026-10-18T03:00:00.000Z","end":"2026-10-18T08:00:00.000Z","running":true,"spentUSD":41,"weekPct":3,"weekQuality":"measured"}],"devices":[{"id":"local","name":"Ege-MacBook-Pro.local","local":true,"spentUSD":32},{"id":"fp-vm","name":"instance-20260829-212457","local":false,"spentUSD":31.599999999999998}],"deviceNotes":[{"id":"fp-old","name":"old-studio","kind":"unsupported"}],"spentLowerBound":true,"previousAtSamePoint":{"at":"2026-10-11T05:10:00.000Z","spentUSD":0,"usedPct":null,"usedQuality":"unknown"}},{"start":"2026-10-10T08:00:00.000Z","end":"2026-10-17T08:00:00.000Z","endReason":"inferred","startInferred":true,"running":false,"spentUSD":0,"tokens":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0},"usedPct":null,"usedQuality":"unknown","fullWeekQuality":"unknown","unpricedModels":[],"models":[],"days":[{"start":"2026-10-10T08:00:00.000Z","end":"2026-10-11T08:00:00.000Z","spentUSD":0,"tokens":0,"usedPct":null},{"start":"2026-10-11T08:00:00.000Z","end":"2026-10-12T08:00:00.000Z","spentUSD":0,"tokens":0,"usedPct":null},{"start":"2026-10-12T08:00:00.000Z","end":"2026-10-13T08:00:00.000Z","spentUSD":0,"tokens":0,"usedPct":null},{"start":"2026-10-13T08:00:00.000Z","end":"2026-10-14T08:00:00.000Z","spentUSD":0,"tokens":0,"usedPct":null},{"start":"2026-10-14T08:00:00.000Z","end":"2026-10-15T08:00:00.000Z","spentUSD":0,"tokens":0,"usedPct":null},{"start":"2026-10-15T08:00:00.000Z","end":"2026-10-16T08:00:00.000Z","spentUSD":0,"tokens":0,"usedPct":null},{"start":"2026-10-16T08:00:00.000Z","end":"2026-10-17T08:00:00.000Z","spentUSD":0,"tokens":0,"usedPct":null}],"sessions":[]},{"start":"2026-10-03T08:00:00.000Z","end":"2026-10-10T08:00:00.000Z","endReason":"inferred","startInferred":true,"running":false,"spentUSD":0,"tokens":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0},"usedPct":null,"usedQuality":"unknown","fullWeekQuality":"unknown","unpricedModels":[],"models":[],"days":[{"start":"2026-10-03T08:00:00.000Z","end":"2026-10-04T08:00:00.000Z","spentUSD":0,"tokens":0,"usedPct":null},{"start":"2026-10-04T08:00:00.000Z","end":"2026-10-05T08:00:00.000Z","spentUSD":0,"tokens":0,"usedPct":null},{"start":"2026-10-05T08:00:00.000Z","end":"2026-10-06T08:00:00.000Z","spentUSD":0,"tokens":0,"usedPct":null},{"start":"2026-10-06T08:00:00.000Z","end":"2026-10-07T08:00:00.000Z","spentUSD":0,"tokens":0,"usedPct":null},{"start":"2026-10-07T08:00:00.000Z","end":"2026-10-08T08:00:00.000Z","spentUSD":0,"tokens":0,"usedPct":null},{"start":"2026-10-08T08:00:00.000Z","end":"2026-10-09T08:00:00.000Z","spentUSD":0,"tokens":0,"usedPct":null},{"start":"2026-10-09T08:00:00.000Z","end":"2026-10-10T08:00:00.000Z","spentUSD":0,"tokens":0,"usedPct":null}],"sessions":[]},{"start":"2026-09-26T08:00:00.000Z","end":"2026-10-03T08:00:00.000Z","endReason":"inferred","startInferred":true,"running":false,"spentUSD":0,"tokens":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0},"usedPct":null,"usedQuality":"unknown","fullWeekQuality":"unknown","unpricedModels":[],"models":[],"days":[{"start":"2026-09-26T08:00:00.000Z","end":"2026-09-27T08:00:00.000Z","spentUSD":0,"tokens":0,"usedPct":null},{"start":"2026-09-27T08:00:00.000Z","end":"2026-09-28T08:00:00.000Z","spentUSD":0,"tokens":0,"usedPct":null},{"start":"2026-09-28T08:00:00.000Z","end":"2026-09-29T08:00:00.000Z","spentUSD":0,"tokens":0,"usedPct":null},{"start":"2026-09-29T08:00:00.000Z","end":"2026-09-30T08:00:00.000Z","spentUSD":0,"tokens":0,"usedPct":null},{"start":"2026-09-30T08:00:00.000Z","end":"2026-10-01T08:00:00.000Z","spentUSD":0,"tokens":0,"usedPct":null},{"start":"2026-10-01T08:00:00.000Z","end":"2026-10-02T08:00:00.000Z","spentUSD":0,"tokens":0,"usedPct":null},{"start":"2026-10-02T08:00:00.000Z","end":"2026-10-03T08:00:00.000Z","spentUSD":0,"tokens":0,"usedPct":null}],"sessions":[]}],"gaps":[],"devices":[{"id":"fp-vm","name":"instance-20260829-212457","status":"ok","through":"2026-10-18T05:09:00.000Z","lastCallAt":"2026-10-18T05:01:00.000Z","lastSyncedAt":"2026-10-18T05:09:30.000Z"},{"id":"fp-old","name":"old-studio","status":"unsupported","through":null,"lastCallAt":null,"lastSyncedAt":null}]}
"""#

    static func report() throws -> ClaudeLimitsReport {
        try ClaudeLimitsReport.decode(Data(json.utf8))
    }
}

@MainActor
final class ClaudeLimitsDevicesTests: XCTestCase {
    func testDecodesDeviceSplitsNotesAndParts() throws {
        let report = try ClaudeLimitsDevicesFixture.report()
        XCTAssertEqual(report.devices?.map(\.status), ["ok", "unsupported"])
        XCTAssertTrue(report.hasPairedDevices)
        XCTAssertEqual(report.latestDeviceCallAt, ClaudeLimitsReport.parseDate("2026-10-18T05:01:00.000Z"))

        let session = try XCTUnwrap(report.current.session)
        XCTAssertEqual(session.devices?.map(\.local), [true, false])
        XCTAssertEqual(session.devices?.first?.spentUSD ?? 0, 31.8, accuracy: 0.001)
        XCTAssertEqual(session.devices?.last?.spentUSD ?? 0, 9.2, accuracy: 0.001)
        XCTAssertEqual(session.deviceNotes?.map(\.kind), [.unsupported])
        XCTAssertTrue(session.spendIsLowerBound)
        XCTAssertEqual(session.fullSessionQuality, .lowerBound)
        let device = try XCTUnwrap(session.chats.first { $0.device != nil })
        XCTAssertEqual(device.device?.name, "instance-20260829-212457")
        XCTAssertNil(device.path)
        XCTAssertEqual(session.hours?.map(\.peerSpentUSD).reduce(0, +) ?? 0, 9.2, accuracy: 0.001)
        XCTAssertEqual(session.models?.first?.peerSpentUSD ?? 0, 9.2, accuracy: 0.001)

        // Yesterday's VM-only session no longer reads as used outside.
        let vmOnly = try XCTUnwrap(report.sessions.last)
        XCTAssertFalse(vmOnly.outsideThisMac)
        XCTAssertEqual(vmOnly.spentUSD, 22.6, accuracy: 0.001)
        XCTAssertNil(vmOnly.deviceNotes)
    }

    /// The Mac-only fixture predates devices and decodes with none.
    func testOlderCLIHasNoDevices() throws {
        let report = try ClaudeLimitsFixture.report()
        XCTAssertNil(report.devices)
        XCTAssertFalse(report.hasPairedDevices)
        XCTAssertNil(report.current.session?.devices)
        XCTAssertEqual(report.current.session?.hours?.first?.peerSpentUSD, 0)
    }

    func testLowerBoundSpendAndValues() {
        XCTAssertEqual(ClaudeSessionFormat.estimatedMoney(114, .lowerBound, symbol: "$", rate: 1), "≥ $114")
        XCTAssertEqual(ClaudeSessionFormat.estimatedMoney(114, .estimated, symbol: "$", rate: 1), "≈ $114")
    }

    func testPairedDeviceWorkCountsAsClaudeActivity() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let local = now.addingTimeInterval(-900)
        let device = now.addingTimeInterval(-60)
        XCTAssertEqual(QuotaRefreshDecision.latestClaudeActivity(localWriteAt: local, deviceCallAt: device, now: now), device)
        XCTAssertEqual(QuotaRefreshDecision.latestClaudeActivity(localWriteAt: nil, deviceCallAt: device, now: now), device)
        XCTAssertEqual(QuotaRefreshDecision.latestClaudeActivity(localWriteAt: local, deviceCallAt: nil, now: now), local)
        XCTAssertNil(QuotaRefreshDecision.latestClaudeActivity(localWriteAt: nil, deviceCallAt: nil, now: now))
        // A device clock ahead of this one never stretches the active window.
        XCTAssertEqual(QuotaRefreshDecision.latestClaudeActivity(localWriteAt: nil, deviceCallAt: now.addingTimeInterval(3600), now: now), now)
        XCTAssertTrue(QuotaRefreshDecision.claudeLiveReadingDue(
            enabled: true, connected: true,
            lastClaudeWriteAt: QuotaRefreshDecision.latestClaudeActivity(localWriteAt: nil, deviceCallAt: device, now: now),
            lastAttemptAt: nil, backoffUntil: nil, lowPowerMode: false, now: now
        ))
    }
}

/// Offscreen renders of the paired-device views at the popover's width.
@Suite("Claude sessions with paired devices layout")
@MainActor
struct ClaudeSessionsDevicesLayoutTests {
    private static let contentWidth: CGFloat = 360 - 28

    private func render<Content: View>(_ name: String, _ content: Content) throws -> CGSize {
        let renderer = ImageRenderer(content: content
            .environment(\.colorScheme, .dark)
            .frame(width: Self.contentWidth)
            .padding(14)
            .background(Color(white: 0.12)))
        renderer.scale = 2
        let image = try #require(renderer.cgImage, "no image for \(name)")
        if let dir = ProcessInfo.processInfo.environment["CODEBURN_LAYOUT_PROOF_DIR"] {
            let rep = NSBitmapImageRep(cgImage: image)
            if let data = rep.representation(using: .png, properties: [:]) {
                try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("claude-devices-\(name).png"))
            }
        }
        return CGSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2)
    }

    @Test("a paired device's spend lays out at 360pt")
    func rendersAtPopoverWidth() throws {
        let report = try ClaudeLimitsDevicesFixture.report()
        let store = AppStore()
        store.suppressRefreshesForTesting()
        store.claudeLimits = report
        let running = try #require(report.current.session)
        let vmOnly = try #require(report.sessions.last)

        let sizes = [
            try render("chats", VStack(alignment: .leading, spacing: 10) {
                ClaudeSessionSpendLine(session: running)
                if let week = report.current.week { ClaudeWeekSpendLine(week: week) }
                ClaudeSessionsList(report: report, expanded: running.id)
            }.environment(store)),
            try render("hours", ClaudeSessionsList(report: report, expanded: running.id, tab: .hours).environment(store)),
            try render("models", ClaudeSessionsList(report: report, expanded: running.id, tab: .models).environment(store)),
            try render("vm-only", ClaudeSessionsList(report: report, expanded: vmOnly.id).environment(store)),
            try render("weeks", ClaudeWeeksList(report: report, weekPace: 88, expanded: report.weeks[0].start).environment(store)),
        ]
        for size in sizes {
            #expect(size.width == Self.contentWidth + 28)
        }
    }
}
