import AppKit
import SwiftUI
import Testing
@testable import CodeBurnMenubar

/// Offscreen layout checks for the Claude session views at the popover's real
/// content width (360pt minus the insight's 14pt insets), and the copy of
/// every shipped language against the fixed columns. When `CODEBURN_LAYOUT_PROOF_DIR` is set, each render is written
/// there as a 2x PNG for review. Fixture evidence, not installed-app
/// validation.
@Suite("Claude sessions layout")
@MainActor
struct ClaudeSessionsLayoutTests {
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
                try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("claude-sessions-\(name).png"))
            }
        }
        return CGSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2)
    }

    /// Rendered in the process's own language. Switching `L10n` here would race
    /// every suite that compares English copy in parallel; the other languages
    /// are measured string by string in `longestLanguageFits` instead.
    @Test("sessions, weeks and the All-tab row lay out at 360pt")
    func rendersAtPopoverWidth() throws {
        let report = try ClaudeLimitsFixture.report()
        let store = AppStore()
        store.suppressRefreshesForTesting()
        store.claudeLimits = report

        let measured = try #require(report.sessions.last)
        let sessions = try render(
            "sessions",
            VStack(alignment: .leading, spacing: 10) {
                if let session = report.current.session { ClaudeSessionSpendLine(session: session) }
                if let week = report.current.week { ClaudeWeekSpendLine(week: week) }
                ClaudeSessionsList(report: report, expanded: measured.id)
            }
            .environment(store)
        )
        let running = try #require(report.current.session)
        let hours = try render("sessions-hours", ClaudeSessionsList(report: report, expanded: running.id, tab: .hours).environment(store))
        let models = try render("sessions-models", ClaudeSessionsList(report: report, expanded: running.id, tab: .models).environment(store))
        let chats = try render("sessions-chats", ClaudeSessionsList(report: report, expanded: running.id, openChat: "a").environment(store))
        let weeks = try render(
            "weeks",
            ClaudeWeeksList(report: report, weekPace: 86, expanded: report.weeks[1].start).environment(store)
        )
        let weekDays = try render("weeks-days", ClaudeWeeksList(report: report, expanded: report.weeks[0].start).environment(store))
        let weekSessions = try render(
            "weeks-sessions",
            ClaudeWeeksList(report: report, expanded: report.weeks[0].start, tab: .sessions).environment(store)
        )
        let row = try render("all-tab", ClaudeSessionAllTabRow(report: report).environment(store))
        // The renders keep the popover width: nothing pushes the content wider.
        for size in [sessions, hours, models, chats, weeks, weekDays, weekSessions, row] {
            #expect(size.width == Self.contentWidth + 28)
        }
        // The All-tab row stays one line (28pt of it is the render padding).
        #expect(row.height - 28 < 34)
    }

    /// Every shipped language's copy for the fixed-width parts, measured at the
    /// fonts the views use: the column headers fit their columns, the caption
    /// and columns fit one line, and the All-tab label leaves room for its value.
    @Test("the longest language still fits the fixed columns", arguments: L10n.supportedLocalizations)
    func longestLanguageFits(language: String) throws {
        let preference = try #require(LanguagePreference(rawValue: language))
        let bundle = L10n.subbundle(for: preference)
        func width(_ key: String, _ size: CGFloat, _ weight: NSFont.Weight, tracking: CGFloat = 0) -> CGFloat {
            let text = L10n.lookup(key, in: bundle)
            let measured = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width
            return measured + tracking * CGFloat(text.count)
        }
        // Column headers are upper-cased in the view.
        func header(_ key: String) -> CGFloat {
            let text = L10n.lookup(key, in: bundle).uppercased(with: Locale(identifier: language))
            let measured = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 8.5, weight: .semibold)]).width
            return measured + 0.3 * CGFloat(text.count)
        }
        // Headers are right-aligned and may lean left into the gap and the
        // unused part of the column before them, never onto its header.
        // Sessions: Spent 40, the 5-hour meter and percent 80, Week 34.
        #expect(header("5-hour") <= 80)
        #expect(header("Week") <= 34 + 4 + (80 - header("5-hour")))
        #expect(header("API prices") + 4 + header("Spent") + 4 + 80 + 4 + 34 <= Self.contentWidth)
        // Weeks: Spent 46, the strip and percent 92, Full week 56.
        #expect(header("Spent") <= 46)
        #expect(header("Used") <= 92)
        #expect(header("Full week") <= 56 + 4 + (92 - header("Used")))
        // The section title next to the Sessions | Weeks switch.
        let title = width("Last 4 weeks", 11, .semibold) + width(" · ", 11, .medium) + width("API prices", 11, .medium)
        let toggle = width("Sessions", 10, .semibold) + width("Weeks", 10, .semibold) + 4 * 9 + 4
        #expect(title * 0.85 + 6 + toggle <= Self.contentWidth)
        // The All-tab row: 14pt insets, the label, the value at its 0.85
        // minimum scale ("61% · $116 · ≈+8% of week" in 10.5pt mono is about
        // 190pt), the chevron.
        let value = (ClaudeSessionFormat.percent(61, .measured) + " · $116 · " + ClaudeSessionFormat.percent(8, .estimated, signed: true)) as NSString
        let valueWidth = value.size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold)]).width
            + width("%1$@ · %2$@ · %3$@ of week", 10.5, .semibold) - width("%1$@ · %2$@ · %3$@", 10.5, .semibold)
        #expect(width("Claude session", 11, .medium) + valueWidth * 0.85 + 6 + 6 + 10 <= 360 - 28)
    }

    /// The whole insight section as the popover shows it: Claude › Plan with
    /// the session and week lines, and Trend › Hours with session bands.
    @Test("Claude Plan and Trend Hours render inside the insight section")
    func rendersPlanAndHours() throws {
        let report = try ClaudeLimitsFixture.report()
        let store = AppStore()
        store.suppressRefreshesForTesting()
        store.claudeLimits = report

        // Today's timeline: a few busy hours inside the fixture's sessions.
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let iso = ISO8601DateFormatter()
        let points = (0..<96).map { quarter -> GranularTimeline.Point in
            let at = start.addingTimeInterval(Double(quarter) * 900)
            let hour = quarter / 4
            let cost = [9, 10, 11, 14, 15, 16].contains(hour) ? Double(quarter % 4 + 1) * 2.5 : 0
            return .init(
                timestamp: iso.string(from: at), cost: cost, tokens: cost * 120_000, models: [],
                sessions: cost > 0 ? [.init(seriesId: "session_0", cost: cost * 0.7, tokens: cost * 84_000), .init(seriesId: "session_1", cost: cost * 0.3, tokens: cost * 36_000)] : []
            )
        }
        let timeline = GranularTimeline(
            bucketMinutes: 15, modelSeries: [],
            sessionSeries: [.init(id: "session_0", label: "Refactor the auth flow (claude)", sessionId: "a"),
                            .init(id: "session_1", label: "Fix onboarding layout (claude)", sessionId: "b")],
            points: points
        )
        let empty = MenubarPayload.empty
        let payload = MenubarPayload(
            generated: "", current: empty.current, optimize: empty.optimize,
            history: HistoryBlock(daily: [], timeline: timeline), combined: nil
        )
        store.selectedScope = .local
        store.selectedPeriod = .today
        store.selectedProvider = .claude
        store.selectedDays = []
        store.setCachedPayloadForTesting(payload, period: .today, provider: .claude, fetchedAt: Date())

        store.selectedInsight = .trend
        store.trendGranularity = .hours
        let hours = try render("trend-hours", HeatmapSection().environment(store))
        #expect(hours.height > 120)

        let reset = Date().addingTimeInterval(3 * 3600)
        store.subscription = SubscriptionUsage(
            tier: .max5x, rawTier: nil,
            fiveHourPercent: 61, fiveHourResetsAt: reset,
            sevenDayPercent: 8, sevenDayResetsAt: Date().addingTimeInterval(6 * 86400),
            sevenDayOpusPercent: nil, sevenDayOpusResetsAt: nil,
            sevenDaySonnetPercent: nil, sevenDaySonnetResetsAt: nil,
            scopedWeekly: [], fetchedAt: Date()
        )
        store.subscriptionLoadState = .loaded
        store.selectedInsight = .plan
        let plan = try render("plan", HeatmapSection().environment(store))
        #expect(plan.height > 300)
    }
}
