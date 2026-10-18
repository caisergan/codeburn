import SwiftUI

struct HeroSection: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption(text: caption)

            HStack(alignment: .firstTextBaseline) {
                Text(heroText)
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .tracking(-1)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Theme.brandAccent, Theme.brandAccentDeep],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    if store.displayMetric == .tokens {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 9, weight: .semibold))
                            Text(formatTokens(Double(totals.outputTokens)))
                        }
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 9, weight: .semibold))
                            Text(formatTokens(Double(totals.inputTokens)))
                        }
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                    } else {
                        Text(totals.calls == 1 ? L("%@ call", totals.calls.asThousandsSeparated()) : L("%@ calls", totals.calls.asThousandsSeparated()))
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text(combinedUsage != nil
                             ? SessionCountLabel.combinedText
                             : SessionCountLabel.text(sessions: totals.sessions, basis: totals.sessionCountBasis))
                            .font(.system(size: 10.5))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                            .help(SessionCountLabel.helpText(combined: combinedUsage != nil, basis: totals.sessionCountBasis))
                    }
                }
            }

            if !store.isDayMode,
               store.selectedPeriod == .today,
               store.shouldShowDailyBudgetWarning {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text(L("Daily budget of %@ exceeded", store.dailyBudgetLabel))
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.orange)
                .padding(.top, 2)
            }

            if let usage = combinedUsage {
                CombinedDeviceBreakdown(usage: usage, formatTokens: formatTokens)
            } else if store.activeScope == .combined, store.lastError != nil {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text(L("Combined unavailable · showing local"))
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.secondary)
            }

            if let savingsCaption {
                HStack(spacing: 4) {
                    Image(systemName: "leaf.fill")
                        .font(.system(size: 10))
                    Text(savingsCaption)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private var heroText: String {
        if store.displayMetric == .tokens || store.displayMetric == .totalTokens {
            let total = Double(totals.totalTokens)
            if total >= 1_000_000_000 { return String(format: "%.2fB tok", total / 1_000_000_000) }
            if total >= 1_000_000 { return String(format: "%.1fM tok", total / 1_000_000) }
            if total >= 1_000 { return String(format: "%.0fK tok", total / 1_000) }
            return String(format: "%.0f tok", total)
        }
        let shown = totals.cost.asCurrency()
        // The combined aggregate carries no estimated split, so it is never marked.
        guard combinedUsage == nil else { return shown }
        let estimated = store.payload.current.providerDetails.reduce(0.0) { $0 + ($1.estimatedCostUSD ?? 0) }
        return (isEstimatedCost(totals.cost, estimated, shown: shown) ? "~" : "") + shown
    }

    private var combinedUsage: CombinedUsage? {
        guard store.activeScope == .combined else { return nil }
        return store.payload.combined
    }

    private var totals: HeroTotals {
        HeroTotals(payload: store.payload, activeScope: store.activeScope)
    }

    private func formatTokens(_ n: Double) -> String {
        if n >= 1_000_000_000 { return String(format: "%.1fB", n / 1_000_000_000) }
        if n >= 1_000_000 { return String(format: "%.1fM", n / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fK", n / 1_000) }
        return String(format: "%.0f", n)
    }

    private var caption: String {
        let label = store.payload.current.label.isEmpty ? store.selectedPeriod.rawValue : store.payload.current.label
        if combinedUsage != nil {
            return L("Combined · %@", label)
        }
        if !store.isDayMode && store.selectedPeriod == .today {
            return "\(label) · \(todayDate)"
        }
        return label
    }

    /// Local-model savings caption shown beneath the hero amount when the
    /// user has mapped any local model to a paid baseline via
    /// `codeburn model-savings`. Kept as a separate line so actual spend
    /// (above) and hypothetical avoided spend (below) never get summed
    /// into a misleading "real cost" by the reader.
    private var savingsCaption: String? {
        guard combinedUsage == nil else { return nil }
        let savings = store.payload.current.localModelSavings.totalUSD
        guard savings > 0 else { return nil }
        return L("Saved %@ with local models", savings.asCurrency())
    }

    private var todayDate: String {
        let formatter = DateFormatter()
        // Localized template, not a fixed pattern: zh-Hans wants "9月11日周五",
        // not "Fri Sep 11".
        formatter.setLocalizedDateFormatFromTemplate("EEE MMM d")
        return formatter.string(from: Date())
    }
}

struct HeroTotals: Equatable {
    let cost: Double
    let calls: Int
    let sessions: Int
    let sessionCountBasis: String?
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int

    init(cost: Double, calls: Int, sessions: Int, inputTokens: Int, outputTokens: Int, totalTokens: Int, sessionCountBasis: String? = nil) {
        self.cost = cost
        self.calls = calls
        self.sessions = sessions
        self.sessionCountBasis = sessionCountBasis
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
    }

    init(payload: MenubarPayload, activeScope: MenubarScope) {
        if activeScope == .combined, let combined = payload.combined?.combined {
            // Keep the numeric wire sum for compatibility. Combined-scope UI
            // must not present it as a unique or lower-bound count.
            self.init(
                cost: combined.cost,
                calls: combined.calls,
                sessions: combined.sessions,
                inputTokens: combined.inputTokens,
                outputTokens: combined.outputTokens,
                totalTokens: combined.inputTokens + combined.outputTokens
            )
            return
        }

        let current = payload.current
        self.init(
            cost: current.cost,
            calls: current.calls,
            sessions: current.sessions,
            inputTokens: current.inputTokens,
            outputTokens: current.outputTokens,
            totalTokens: current.inputTokens + current.outputTokens,
            sessionCountBasis: current.sessionCountBasis
        )
    }
}

private struct CombinedDeviceBreakdown: View {
    @Environment(AppStore.self) private var store
    let usage: CombinedUsage
    let formatTokens: (Double) -> String
    /// The device whose re-pair steps are open under its row.
    @State private var repairingDeviceId: String?

    /// Failed paired devices a retry could bring back.
    private var retryableIds: [String] {
        usage.perDevice
            .filter { !$0.local && $0.error.map { PairedDeviceFailure(error: $0).canRetry } == true }
            .map(\.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 10))
                Text(L("%1$lld of %2$lld devices", usage.combined.reachableCount, usage.combined.deviceCount))
                    .font(.system(size: 11, weight: .medium))
                    .contentTransition(.numericText())
                if retryableIds.count >= 2 {
                    Spacer(minLength: 6)
                    Button {
                        Task { await store.retryDevices(retryableIds) }
                    } label: {
                        Label(L("Retry all"), systemImage: "arrow.clockwise")
                            .font(.system(size: 10.5, weight: .medium))
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.brandAccent)
                    .disabled(retryableIds.allSatisfy(store.retryingDeviceIds.contains))
                }
            }
            .foregroundStyle(.secondary)

            VStack(spacing: 3) {
                ForEach(usage.perDevice, id: \.id) { device in
                    CombinedDeviceRow(
                        device: device,
                        formatTokens: formatTokens,
                        isRepairOpen: repairingDeviceId == device.id,
                        toggleRepair: {
                            repairingDeviceId = repairingDeviceId == device.id ? nil : device.id
                        }
                    )
                    if repairingDeviceId == device.id, device.error != nil {
                        RepairDeviceSteps(device: device)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: repairingDeviceId)
        .onChange(of: usage.perDevice.map(\.error)) {
            // Close the steps once the device answers again.
            if let id = repairingDeviceId,
               usage.perDevice.first(where: { $0.id == id })?.error == nil {
                repairingDeviceId = nil
            }
        }
    }
}

private struct CombinedDeviceRow: View {
    @Environment(AppStore.self) private var store
    let device: CombinedDeviceUsage
    let formatTokens: (Double) -> String
    let isRepairOpen: Bool
    let toggleRepair: () -> Void
    /// Brief highlight when a retry brings the device back.
    @State private var flash = false

    private var isRetrying: Bool { store.retryingDeviceIds.contains(device.id) }

    var body: some View {
        HStack(spacing: 6) {
            leadingIcon
                .frame(width: 10, height: 10)
            Text(device.local ? L("%@ · local", device.name) : device.name)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            if let error = device.error {
                failureTrailing(PairedDeviceFailure(error: error))
            } else {
                Group {
                    Text(device.cost.asCurrency())
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Text(formatTokens(Double(device.totalTokens)))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .monospacedDigit()
                .transition(.opacity)
            }
        }
        .frame(minHeight: 16)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Theme.semanticSuccess.opacity(flash ? 0.16 : 0))
                .padding(.horizontal, -4)
                .padding(.vertical, -1)
        )
        .help(device.error.map {
            PairedDeviceFailure.helpText(error: $0, address: device.address, lastTriedAt: store.deviceLastRetriedAt[device.id])
        } ?? "")
        .animation(.easeOut(duration: 0.25), value: device.error == nil)
        .animation(.easeOut(duration: 0.15), value: isRetrying)
        .onChange(of: device.error == nil) { _, reachable in
            // Only a retry the user asked for earns the highlight.
            guard reachable, store.deviceLastRetriedAt[device.id] != nil else { return }
            flash = true
            withAnimation(.easeOut(duration: 1.2).delay(0.2)) { flash = false }
        }
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if isRetrying {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.6)
        } else if device.error == nil {
            Image(systemName: "circle.fill")
                .font(.system(size: 5, weight: .semibold))
                .foregroundStyle(Color.secondary.opacity(0.75))
        } else {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.semanticWarning)
        }
    }

    @ViewBuilder
    private func failureTrailing(_ failure: PairedDeviceFailure) -> some View {
        let stillFailing = store.deviceRetryStillFailingIds.contains(device.id)
        Text(isRetrying ? L("Connecting…") : stillFailing ? L("Still unreachable") : failure.label)
            .font(.system(size: 10.5, weight: stillFailing ? .semibold : .regular))
            .foregroundStyle(isRetrying ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.semanticWarning))
            .contentTransition(.opacity)
        if !device.local {
            if failure.canRetry {
                Button {
                    Task { await store.retryDevices([device.id]) }
                } label: {
                    Label(L("Retry"), systemImage: "arrow.clockwise")
                        .font(.system(size: 10, weight: .medium))
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(isRetrying)
            } else {
                Button(action: toggleRepair) {
                    Text(L("Re-pair"))
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(Theme.brandAccent)
                .foregroundStyle(Theme.brandAccent)
                .opacity(isRepairOpen ? 0.7 : 1)
            }
        }
    }
}

/// Pairing lives in the CLI: a PIN from the other device, then `devices add`
/// here. Adding a device it already has replaces the old token.
private struct RepairDeviceSteps: View {
    let device: CombinedDeviceUsage

    private var addCommand: String {
        "codeburn devices add \(device.address ?? "<host:port>") --pin <PIN>"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            step(L("1. On %@, run:", device.name), command: "codeburn share --pair")
            step(L("2. Then here, with the PIN it shows:"), command: addCommand)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
        .padding(.leading, 16)
        .padding(.vertical, 2)
    }

    private func step(_ title: String, command: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(command)
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(L("Copy"))
            }
        }
    }
}
