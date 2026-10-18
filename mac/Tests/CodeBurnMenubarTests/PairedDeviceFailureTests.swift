import Foundation
import Testing
@testable import CodeBurnMenubar

@Suite("Paired device failures")
struct PairedDeviceFailureTests {
    @Test("classifies the errors the CLI reports for a paired device")
    func classifies() {
        #expect(PairedDeviceFailure(error: "peer unreachable") == .unreachable)
        #expect(PairedDeviceFailure(error: "connect ECONNREFUSED 100.84.12.7:7777") == .unreachable)
        #expect(PairedDeviceFailure(error: "connect EHOSTUNREACH 100.84.12.7:7777") == .unreachable)
        #expect(PairedDeviceFailure(error: "getaddrinfo ENOTFOUND vm.local") == .unreachable)
        #expect(PairedDeviceFailure(error: "peer timed out") == .timedOut)
        #expect(PairedDeviceFailure(error: "connect ETIMEDOUT 100.84.12.7:7777") == .timedOut)
        #expect(PairedDeviceFailure(error: "not authorized (re-pair?)") == .unauthorized)
        #expect(PairedDeviceFailure(error: "HTTP 500") == .other)
        #expect(PairedDeviceFailure(error: "server fingerprint mismatch") == .other)
    }

    @Test("only an auth failure cannot be retried")
    func retryable() {
        #expect(PairedDeviceFailure.unreachable.canRetry)
        #expect(PairedDeviceFailure.timedOut.canRetry)
        #expect(PairedDeviceFailure.other.canRetry)
        #expect(!PairedDeviceFailure.unauthorized.canRetry)
    }

    @Test("help text names the address, the raw error, and what to check")
    func helpText() {
        let text = PairedDeviceFailure.helpText(error: "peer unreachable", address: "100.84.12.7:7777", lastTriedAt: nil)
        #expect(text.contains("100.84.12.7:7777"))
        #expect(text.contains("peer unreachable"))
        #expect(text.contains("Tailscale"))
        #expect(!text.contains("Last tried"))

        let tried = PairedDeviceFailure.helpText(error: "peer unreachable", address: nil, lastTriedAt: Date())
        #expect(tried.contains("Last tried"))
        #expect(!tried.contains("Couldn't reach"))

        let auth = PairedDeviceFailure.helpText(error: "not authorized (re-pair?)", address: "vm:7777", lastTriedAt: nil)
        #expect(auth.contains("Pair it again"))
    }

    @Test("decodes a device's address, and tolerates a CLI that omits it")
    func decodesAddress() throws {
        let json = """
        [{"id":"fp","name":"vm","local":false,"address":"100.84.12.7:7777","error":"peer unreachable","cost":0,"calls":0,"sessions":0,"inputTokens":0,"outputTokens":0,"cacheCreateTokens":0,"cacheReadTokens":0,"totalTokens":0},
         {"id":"local","name":"mac","local":true,"cost":1,"calls":1,"sessions":1,"inputTokens":1,"outputTokens":1,"cacheCreateTokens":0,"cacheReadTokens":0,"totalTokens":2}]
        """
        let devices = try JSONDecoder().decode([CombinedDeviceUsage].self, from: Data(json.utf8))
        #expect(devices[0].address == "100.84.12.7:7777")
        #expect(devices[1].address == nil)
    }

    @Test("the retry variant of limits still runs on the resident child")
    func retrySubcommandIsServed() {
        #expect(DataClient.claudeLimitsRetrySubcommand == ["limits", "--format", "json", "--devices", "--retry-failed"])
        #expect(ServeConnection.isEligible(DataClient.claudeLimitsRetrySubcommand))
    }
}
