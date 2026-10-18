import Foundation

/// Why a paired device's row in Combined has no numbers, read from the
/// `error` the CLI reports for it (`src/sharing/host.ts`, `client.ts`).
enum PairedDeviceFailure: Equatable {
    /// Nothing answered: the device is off, or the VPN/Tailscale is down.
    case unreachable
    /// It connected but did not answer in time.
    case timedOut
    /// It no longer accepts this Mac's token; retrying cannot help.
    case unauthorized
    case other

    init(error: String) {
        let e = error.lowercased()
        if e.contains("not authorized") || e.contains("http 401") {
            self = .unauthorized
        } else if e.contains("timed out") || e.contains("etimedout") {
            self = .timedOut
        } else if ["unreachable", "econnrefused", "ehostunreach", "enetunreach", "enotfound", "eai_again", "econnreset"]
                    .contains(where: e.contains) {
            self = .unreachable
        } else {
            self = .other
        }
    }

    var label: String {
        switch self {
        case .unreachable: return L("Unreachable")
        case .timedOut: return L("Timed out")
        case .unauthorized: return L("Not authorized")
        case .other: return L("Unavailable")
        }
    }

    var canRetry: Bool { self != .unauthorized }

    /// The row's hover text: what failed, where, and what to check.
    static func helpText(error: String, address: String?, lastTriedAt: Date?) -> String {
        let failure = PairedDeviceFailure(error: error)
        var lines: [String] = []
        if let address {
            lines.append(failure == .unauthorized
                ? L("%@ refused this Mac's token.", address)
                : L("Couldn't reach %@.", address))
        }
        lines.append(error)
        switch failure {
        case .unreachable, .timedOut:
            lines.append(L("Check that the device is on and your VPN or Tailscale is connected."))
        case .unauthorized:
            lines.append(L("Pair it again to fix this."))
        case .other:
            break
        }
        if let lastTriedAt {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            lines.append(L("Last tried %@", formatter.string(from: lastTriedAt)))
        }
        return lines.joined(separator: "\n")
    }
}
