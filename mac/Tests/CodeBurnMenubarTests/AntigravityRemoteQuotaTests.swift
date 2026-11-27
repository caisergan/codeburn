import XCTest
@testable import CodeBurnMenubar

/// The remote Antigravity quota read (keychain grant → in-memory token renewal
/// → loadCodeAssist → retrieveUserQuotaSummary) and the warmer's pure rules.
/// Every keychain read, binary scan and HTTP call goes through injected seams;
/// nothing touches the real keychain or the network.
final class AntigravityRemoteQuotaTests: XCTestCase {

    private static let now = Date(timeIntervalSince1970: 1_795_000_000)
    // Fake values in the real shapes, assembled at runtime so secret
    // scanners don't mistake the fixtures for live credentials.
    private static let host = [".apps", "googleusercontent", "com"].joined(separator: ".")
    private static let clientId = "1234567890-" + "abcdefghijklmnopqrstuvwxyz012345" + host
    private static let otherId = "9876543210-" + "zyxwvutsrqponmlkjihgfedcba543210" + host
    private static let secretPrefix = ["GOC", "SPX-"].joined()
    private static let secret = secretPrefix + "AAAAbbbbCCCCddddEEEEffff1234"
    private static let otherSecret = secretPrefix + "ZZZZyyyyXXXXwwwwVVVVuuuu9876"

    private static let summaryJSON = """
    {"groups":[
      {"displayName":"Gemini Models","description":"Models within this group: Gemini 3.8 Flash",
       "buckets":[
         {"bucketId":"gemini-weekly","window":"weekly","displayName":"Weekly Limit Remaining","resetTime":"2026-12-04T15:04:49Z","remainingFraction":0.85},
         {"bucketId":"gemini-5h","window":"5h","displayName":"Five Hour Limit Remaining","resetTime":"2026-11-28T02:02:39Z","remainingFraction":0.99}]},
      {"displayName":"Claude and GPT models","description":"Models within this group: Claude Opus 5.5, Claude Sonnet 5.5, GPT-OSS 120B",
       "buckets":[
         {"bucketId":"3p-weekly","window":"weekly","displayName":"Weekly Limit Remaining","remainingFraction":1},
         {"bucketId":"3p-5h","window":"5h","displayName":"Five Hour Limit Remaining","remainingFraction":1}]}]}
    """

    override func setUp() async throws {
        await AntigravityRemoteQuota.resetCache()
    }

    private static func grantValue(expiry: Date, refresh: String? = "1//refresh-token") -> String {
        let formatter = ISO8601DateFormatter()
        var token: [String: Any] = ["access_token": "ya29.stored", "token_type": "Bearer", "expiry": formatter.string(from: expiry)]
        if let refresh { token["refresh_token"] = refresh }
        let json = try! JSONSerialization.data(withJSONObject: ["token": token, "auth_method": "consumer"])
        return "go-keyring-base64:" + json.base64EncodedString()
    }

    private final class Recorder: @unchecked Sendable {
        var requests: [URLRequest] = []
    }

    private static func response(_ url: URL, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private static func deps(
        keychain: String?,
        binary: String = "",
        recorder: Recorder,
        handler: @escaping @Sendable (URLRequest) -> (Int, String)
    ) -> AntigravityRemoteQuota.Deps {
        AntigravityRemoteQuota.Deps(
            readKeychain: { keychain },
            binaries: { binary.isEmpty ? [] : [Data(binary.utf8)] },
            appVersion: { "2.35.2" },
            fetch: { request in
                recorder.requests.append(request)
                let (status, body) = handler(request)
                return (Data(body.utf8), response(request.url!, status))
            },
            now: { now }
        )
    }

    private static func defaultHandler(_ request: URLRequest) -> (Int, String) {
        let url = request.url!.absoluteString
        if url.hasSuffix(":loadCodeAssist") {
            return (200, #"{"cloudaicompanionProject":"aicode-consumers","currentTier":{"name":"Antigravity"},"paidTier":{"name":"Google AI Pro"}}"#)
        }
        if url.hasSuffix(":retrieveUserQuotaSummary") { return (200, summaryJSON) }
        return (404, "{}")
    }

    // MARK: Grant

    func testParsesGoKeyringGrant() {
        let grant = AntigravityRemoteQuota.parseGrant(Self.grantValue(expiry: Self.now))
        XCTAssertEqual(grant?.accessToken, "ya29.stored")
        XCTAssertEqual(grant?.refreshToken, "1//refresh-token")
        XCTAssertEqual(grant?.expiry, Self.now)
    }

    func testParsesGoNanosecondExpiry() {
        let date = AntigravityRemoteQuota.parseDate("2026-11-28T00:12:32.534079123+03:00")
        XCTAssertEqual(date?.timeIntervalSince1970 ?? 0, 1_795_813_952.534, accuracy: 0.01)
    }

    func testRejectsGarbageGrant() {
        XCTAssertNil(AntigravityRemoteQuota.parseGrant("go-keyring-base64:not-base64!"))
        XCTAssertNil(AntigravityRemoteQuota.parseGrant(#"{"token":{"access_token":""}}"#))
    }

    // MARK: OAuth client discovery

    func testFindsClientIdsAndSecretsPackedTogether() {
        // Go packs string constants back to back.
        let blob = "xx/oauth\(Self.clientId)https://auth\(Self.secret)://cloudcode\(Self.otherSecret).sandbox 12-short\(Self.host)"
        let found = AntigravityRemoteQuota.clientCandidates(in: Data(blob.utf8))
        XCTAssertEqual(found.ids, [Self.clientId])
        XCTAssertEqual(found.secrets, [Self.secret, Self.otherSecret])
    }

    // MARK: Fetch

    func testValidStoredTokenSkipsRenewal() async throws {
        let recorder = Recorder()
        let deps = Self.deps(keychain: Self.grantValue(expiry: Self.now.addingTimeInterval(1800)), recorder: recorder,
                             handler: Self.defaultHandler)
        let usage = try await AntigravityRemoteQuota.fetch(deps: deps)
        XCTAssertEqual(usage.source, .remote)
        XCTAssertEqual(usage.plan, "Google AI Pro")
        XCTAssertEqual(usage.groups.map(\.id), ["gemini", "3p"])
        XCTAssertEqual(usage.details.first?.label, "Gemini Models · Weekly Limit used")
        let urls = recorder.requests.map { $0.url!.absoluteString }
        XCTAssertEqual(urls, [
            "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist",
            "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
        ])
        XCTAssertEqual(recorder.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer ya29.stored")
        XCTAssertTrue(recorder.requests[0].value(forHTTPHeaderField: "User-Agent")?.hasPrefix("antigravity/2.35.2 darwin/") == true)
        let quotaBody = try JSONSerialization.jsonObject(with: recorder.requests[1].httpBody!) as? [String: String]
        XCTAssertEqual(quotaBody, ["project": "aicode-consumers"])
    }

    func testExpiredTokenIsRenewedWithTheClientThatOwnsIt() async throws {
        let recorder = Recorder()
        let binary = "\(Self.otherId)..\(Self.clientId)..\(Self.otherSecret)..\(Self.secret)"
        let deps = Self.deps(keychain: Self.grantValue(expiry: Self.now.addingTimeInterval(-60)), binary: binary,
                             recorder: recorder) { request in
            if request.url!.absoluteString == AntigravityRemoteQuota.tokenEndpoint {
                let form = String(decoding: request.httpBody!, as: UTF8.self)
                if form.contains("client_id=\(Self.clientId)"), form.contains("client_secret=\(Self.secret)") {
                    return (200, #"{"access_token":"ya29.renewed","expires_in":3599}"#)
                }
                return (401, #"{"error":"invalid_client"}"#)
            }
            return Self.defaultHandler(request)
        }
        let usage = try await AntigravityRemoteQuota.fetch(deps: deps)
        XCTAssertEqual(usage.plan, "Google AI Pro")
        let assist = recorder.requests.first { $0.url!.absoluteString.hasSuffix(":loadCodeAssist") }
        XCTAssertEqual(assist?.value(forHTTPHeaderField: "Authorization"), "Bearer ya29.renewed")
        let form = String(decoding: recorder.requests.first!.httpBody!, as: UTF8.self)
        XCTAssertTrue(form.contains("grant_type=refresh_token"))
        XCTAssertTrue(form.contains("refresh_token=1//refresh-token"))
    }

    func testRevokedGrantIsSignedOut() async {
        let recorder = Recorder()
        let deps = Self.deps(keychain: Self.grantValue(expiry: Self.now.addingTimeInterval(-60), refresh: "1//revoked"),
                             binary: "\(Self.clientId) \(Self.secret)", recorder: recorder) { request in
            if request.url!.absoluteString == AntigravityRemoteQuota.tokenEndpoint {
                return (400, #"{"error":"invalid_grant"}"#)
            }
            return Self.defaultHandler(request)
        }
        do {
            _ = try await AntigravityRemoteQuota.fetch(deps: deps)
            XCTFail("expected signedOut")
        } catch {
            XCTAssertEqual(error as? AntigravityRemoteQuota.FetchError, .signedOut)
        }
        XCTAssertFalse(recorder.requests.contains { $0.url!.absoluteString.contains("cloudcode") })
    }

    func testNoClientInAnyBinary() async {
        let deps = Self.deps(keychain: Self.grantValue(expiry: Self.now.addingTimeInterval(-60), refresh: "1//no-client"),
                             recorder: Recorder(), handler: Self.defaultHandler)
        do {
            _ = try await AntigravityRemoteQuota.fetch(deps: deps)
            XCTFail("expected clientNotFound")
        } catch {
            XCTAssertEqual(error as? AntigravityRemoteQuota.FetchError, .clientNotFound)
        }
    }

    func testNoKeychainItem() async {
        let deps = Self.deps(keychain: nil, recorder: Recorder(), handler: Self.defaultHandler)
        do {
            _ = try await AntigravityRemoteQuota.fetch(deps: deps)
            XCTFail("expected noGrant")
        } catch {
            XCTAssertEqual(error as? AntigravityRemoteQuota.FetchError, .noGrant)
        }
    }

    func testUnauthorizedStoredTokenIsRenewedOnce() async throws {
        let recorder = Recorder()
        let deps = Self.deps(keychain: Self.grantValue(expiry: Self.now.addingTimeInterval(1800), refresh: "1//retry"),
                             binary: "\(Self.clientId) \(Self.secret)", recorder: recorder) { request in
            let url = request.url!.absoluteString
            if url == AntigravityRemoteQuota.tokenEndpoint { return (200, #"{"access_token":"ya29.fresh","expires_in":3599}"#) }
            if url.hasSuffix(":loadCodeAssist"), request.value(forHTTPHeaderField: "Authorization") == "Bearer ya29.stored" {
                return (401, "{}")
            }
            return Self.defaultHandler(request)
        }
        let usage = try await AntigravityRemoteQuota.fetch(deps: deps)
        XCTAssertEqual(usage.groups.count, 2)
        XCTAssertEqual(recorder.requests.filter { $0.url!.absoluteString.hasSuffix(":loadCodeAssist") }.count, 2)
    }

    // MARK: Fallback from the local probe

    func testLocalProbeFallsBackToRemote() async throws {
        let remote = AntigravityUsage(details: [], plan: "Google AI Pro", fetchedAt: Self.now, source: .remote)
        let deps = AntigravitySubscriptionService.Deps(
            exec: { _, _ in "" },
            request: { _, _, _, _, _ in nil },
            now: { Self.now },
            log: { _ in },
            remote: { remote }
        )
        let usage = try await AntigravitySubscriptionService.refresh(deps: deps)
        XCTAssertEqual(usage, remote)
    }

    func testSignedOutRemoteMapsToSignedOut() async {
        let deps = AntigravitySubscriptionService.Deps(
            exec: { _, _ in "" },
            request: { _, _, _, _, _ in nil },
            now: { Self.now },
            log: { _ in },
            remote: { throw AntigravityRemoteQuota.FetchError.signedOut }
        )
        do {
            _ = try await AntigravitySubscriptionService.refresh(deps: deps)
            XCTFail("expected signedOut")
        } catch AntigravitySubscriptionService.FetchError.signedOut {
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: Groups and idle

    func testDecodesGroupsWithModels() throws {
        let parsed = try JSONSerialization.jsonObject(with: Data(Self.summaryJSON.utf8))
        let groups = AntigravitySubscriptionService.decodeGroups(parsed)
        XCTAssertEqual(groups.map(\.id), ["gemini", "3p"])
        XCTAssertEqual(groups[1].models, ["Claude Opus 5.5", "Claude Sonnet 5.5", "GPT-OSS 120B"])
        XCTAssertEqual(groups[0].fiveHour?.remainingFraction, 0.99)
        XCTAssertNotNil(groups[0].weekly?.resetsAt)
        XCTAssertNil(groups[1].fiveHour?.resetsAt)
    }

    func testIdleMeansFullAndNoFixedReset() {
        typealias Group = AntigravityUsage.Group
        let now = Self.now
        func group(_ remaining: Double, _ resets: Date?) -> Group {
            Group(id: "gemini", name: "Gemini", models: [], fiveHour: .init(remainingFraction: remaining, resetsAt: resets), weekly: nil)
        }
        XCTAssertTrue(group(1, nil).isFiveHourIdle(now: now))
        // An unused group's reset slides to now + 5 h.
        XCTAssertTrue(group(1, now.addingTimeInterval(5 * 3600)).isFiveHourIdle(now: now))
        // A started window has a fixed reset, even at 100% remaining.
        XCTAssertFalse(group(1, now.addingTimeInterval(4 * 3600)).isFiveHourIdle(now: now))
        XCTAssertFalse(group(0.99, now.addingTimeInterval(5 * 3600)).isFiveHourIdle(now: now))
    }

    // MARK: Warm rules

    func testPicksTheCheapestModelOfEachGroup() {
        let models = AntigravityWarmRules.parseModels("""
        Fetching available models...
        gemini-4-neon-high\tGemini 4 Neon (High)
        gemini-3.8-flash-high\tGemini 3.8 Flash (High)
        gemini-3.8-flash-low\tGemini 3.8 Flash (Low)
        claude-opus-5-5-low\tClaude Opus 5.5 (Low)
        claude-sonnet-5-5-low\tClaude Sonnet 5.5 (Low)
        gpt-oss-120b-medium\tGPT-OSS 120B (Medium)
        """)
        XCTAssertEqual(models.count, 6)
        XCTAssertEqual(AntigravityWarmRules.warmModel(groupId: "gemini", groupModels: ["Gemini 3.8 Flash"], available: models),
                       "gemini-3.8-flash-low")
        XCTAssertEqual(AntigravityWarmRules.warmModel(groupId: "3p", groupModels: ["Claude Opus 5.5", "Claude Sonnet 5.5", "GPT-OSS 120B"], available: models),
                       "gpt-oss-120b-medium")
        // No model list (legacy payload): fall back on the group id.
        XCTAssertEqual(AntigravityWarmRules.warmModel(groupId: "gemini", groupModels: [], available: models), "gemini-3.8-flash-low")
        XCTAssertNil(AntigravityWarmRules.warmModel(groupId: "other", groupModels: ["Nope"], available: models))
    }

    func testWarmCommandAttachesThePrompt() {
        let args = AntigravityWarmRules.warmArguments(model: "gemini-3.8-flash-low")
        XCTAssertEqual(args.last, "--print=Reply with OK.")
        XCTAssertFalse(args.contains("-p"))
        XCTAssertTrue(AntigravityWarmRules.strippedEnvironment.contains("GEMINI_API_KEY"))
    }

    func testSendOutcome() {
        let ok = AntigravityWarmRules.sendOutcome(exitCode: 0, stdout: #"{"conversation_id":"x","status":"SUCCESS","response":"OK."}"#, stderr: "warning: x")
        XCTAssertTrue(ok.ok)
        let signedOut = AntigravityWarmRules.sendOutcome(exitCode: 1, stdout: "", stderr: "Error: You are not logged into Antigravity.")
        XCTAssertEqual(signedOut.reason, "signed_out")
        let failed = AntigravityWarmRules.sendOutcome(exitCode: 1, stdout: "", stderr: "quota exhausted")
        XCTAssertEqual(failed.reason, "send_failed")
        XCTAssertEqual(failed.detail, "quota exhausted")
    }

    func testAutoWarmRules() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        let reset = calendar.date(from: DateComponents(year: 2026, month: 11, day: 28, hour: 15, minute: 0))!
        var prefs = AntigravityWarmPrefs()
        prefs.schedule.autoEnabled = true
        let used = AntigravityTrackedWindow(resetsAt: reset, maxPercent: 40)
        let at = reset.addingTimeInterval(90)
        XCTAssertTrue(AntigravityWarmRules.shouldAutoWarm(prefs: prefs, group: "gemini", window: used, history: [], now: at, calendar: calendar))
        // Group not selected, warm-only window, too late, too early, overnight.
        XCTAssertFalse(AntigravityWarmRules.shouldAutoWarm(prefs: prefs, group: "3p", window: used, history: [], now: at, calendar: calendar))
        XCTAssertFalse(AntigravityWarmRules.shouldAutoWarm(prefs: prefs, group: "gemini", window: .init(resetsAt: reset, maxPercent: 1), history: [], now: at, calendar: calendar))
        XCTAssertFalse(AntigravityWarmRules.shouldAutoWarm(prefs: prefs, group: "gemini", window: used, history: [], now: reset.addingTimeInterval(11 * 60), calendar: calendar))
        XCTAssertFalse(AntigravityWarmRules.shouldAutoWarm(prefs: prefs, group: "gemini", window: used, history: [], now: reset.addingTimeInterval(30), calendar: calendar))
        let night = calendar.date(from: DateComponents(year: 2026, month: 11, day: 28, hour: 3, minute: 0))!
        XCTAssertFalse(AntigravityWarmRules.shouldAutoWarm(prefs: prefs, group: "gemini", window: .init(resetsAt: night, maxPercent: 40),
                                                           history: [], now: night.addingTimeInterval(90), calendar: calendar))
        // Daily cap: five automatic or scheduled starts today.
        let starts = (0..<5).map { index in
            AntigravityWarmResult(at: reset.addingTimeInterval(-Double(index + 1) * 3600), trigger: "auto", group: "gemini",
                                  groupName: "Gemini", outcome: "started", reason: nil, detail: nil)
        }
        XCTAssertFalse(AntigravityWarmRules.shouldAutoWarm(prefs: prefs, group: "gemini", window: used, history: starts, now: at, calendar: calendar))
        prefs.schedule.autoEnabled = false
        XCTAssertFalse(AntigravityWarmRules.shouldAutoWarm(prefs: prefs, group: "gemini", window: used, history: [], now: at, calendar: calendar))
    }

    func testPrefsDecodeWithDefaults() throws {
        let prefs = try JSONDecoder().decode(AntigravityWarmPrefs.self, from: Data("{}".utf8))
        XCTAssertEqual(prefs.groups, ["gemini"])
        XCTAssertFalse(prefs.schedule.enabled)
    }
}
