import SwiftUI

/// Antigravity › Plan: the Sessions | Weeks section Claude has, for one quota
/// group at a time. The models of a group share a 5-hour and a weekly limit, so
/// each group has its own sessions and weeks; a switch picks the group when
/// more than one has been used.
struct AntigravitySessionsPlanSection: View {
    let report: AntigravityLimitsReport
    /// Each group's 7-day "on pace" projection in percent, keyed by group id.
    var weekPaces: [String: Double] = [:]
    /// The group picked by hand; nil follows the one in use.
    @State private var picked: String?

    private struct GroupOption: Hashable {
        let id: String
        let shortName: String
    }

    var body: some View {
        let groups = report.shownGroups
        let selectedID = picked.flatMap { id in groups.contains { $0.id == id } ? id : nil }
            ?? report.defaultGroupID
            ?? groups.first?.id
        if let group = groups.first(where: { $0.id == selectedID }) {
            VStack(alignment: .leading, spacing: 8) {
                if groups.count > 1 {
                    HStack(alignment: .center, spacing: 6) {
                        Text(caps(L("Quota group")))
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 6)
                        ClaudeSegmented(
                            options: groups.map { GroupOption(id: $0.id, shortName: $0.shortName) },
                            label: \.shortName,
                            selection: Binding(
                                get: { GroupOption(id: group.id, shortName: group.shortName) },
                                set: { picked = $0.id }
                            ),
                            mini: true
                        )
                    }
                } else {
                    Text(caps(group.name))
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                ClaudeSessionsPlanSection(report: group.report, weekPace: weekPaces[group.id])
                    .environment(\.limitsProvider, .antigravity)
                    // A fresh list per group: an open row belongs to one.
                    .id(group.id)
            }
        }
    }
}
