import Foundation

/// Antigravity quota while the Antigravity app is closed: the same read-only
/// Google calls the app makes for its own quota panel, using the sign-in the
/// app and the `agy` CLI keep in the login keychain.
///
/// - Grant: login keychain, service `gemini`, account `antigravity`, read with
///   `/usr/bin/security` (the item's ACL already trusts it, so no prompt). The
///   value is `go-keyring-base64:` + JSON `{token:{access_token,
///   refresh_token, expiry}, id_token_email, …}`. Read-only: nothing is ever
///   written back, so the app's own sign-in is never touched.
/// - Token: the stored access token while it is valid. Once it expires (an
///   hour after the app last ran) it is renewed in memory with the refresh
///   token and Antigravity's own OAuth client, read from the installed app's
///   binary. Google does not rotate the refresh token on renewal, so this
///   never signs the app out.
/// - Calls: POST `daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`
///   (plan name + quota project), then `:retrieveUserQuotaSummary` (the
///   groups/buckets payload the local server returns too). Both need
///   Antigravity's user agent; without it Google answers UNSUPPORTED_CLIENT.
///
/// Only quota is read here. CodeBurn never sends a chat message with this
/// token; warms go through the user's own `agy` (see AntigravityWarmer).
enum AntigravityRemoteQuota {
    static let endpoint = "https://daily-cloudcode-pa.googleapis.com/v1internal"
    static let tokenEndpoint = "https://oauth2.googleapis.com/token"
    static let keychainService = "gemini"
    static let keychainAccount = "antigravity"
    /// A token this close to expiry is renewed first.
    static let expiryMargin: TimeInterval = 120

    enum FetchError: Error, Equatable {
        /// No Antigravity sign-in in the keychain.
        case noGrant
        /// Google refused the refresh token: the sign-in was revoked or ended.
        case signedOut
        /// The token expired and no installed Antigravity binary carries an
        /// OAuth client that renews it.
        case clientNotFound
        case http(Int)
        case network(String)
    }

    struct Grant: Equatable, Sendable {
        let accessToken: String
        let refreshToken: String?
        let expiry: Date?
    }

    struct OAuthClient: Equatable, Sendable {
        let id: String
        let secret: String
    }

    // MARK: - Injectable seams

    struct Deps: Sendable {
        /// The keychain value, or nil when there is no item.
        var readKeychain: @Sendable () async -> String?
        /// Memory-mapped bytes of each installed Antigravity binary that may
        /// carry the OAuth client, in the order to try.
        var binaries: @Sendable () -> [Data]
        /// The installed app's version, for the user agent.
        var appVersion: @Sendable () -> String?
        var fetch: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
        var now: @Sendable () -> Date

        static let live = Deps(
            readKeychain: {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
                process.arguments = ["find-generic-password", "-s", keychainService, "-a", keychainAccount, "-w"]
                guard let result = try? await DataClient.runProcess(process, timeoutSeconds: 10, label: "antigravity keychain"),
                      result.exitCode == 0 else { return nil }
                let value = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            },
            binaries: {
                AntigravityInstall.oauthBinaryPaths().compactMap {
                    try? Data(contentsOf: URL(fileURLWithPath: $0), options: .alwaysMapped)
                }
            },
            appVersion: { AntigravityInstall.appVersion() },
            fetch: { request in
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw FetchError.http(-1) }
                return (data, http)
            },
            now: { Date() }
        )
    }

    // MARK: - Grant

    static func parseGrant(_ raw: String) -> Grant? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var json: Data?
        if trimmed.hasPrefix("{") {
            json = Data(trimmed.utf8)
        } else if let colon = trimmed.lastIndex(of: ":") {
            json = base64Decode(String(trimmed[trimmed.index(after: colon)...]))
        } else {
            json = base64Decode(trimmed)
        }
        guard let json,
              let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return nil }
        let token = root["token"] as? [String: Any] ?? root
        guard let access = token["access_token"] as? String, !access.isEmpty else { return nil }
        let refresh = (token["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Grant(accessToken: access, refreshToken: refresh, expiry: parseDate(token["expiry"]))
    }

    private static func base64Decode(_ value: String) -> Data? {
        var padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded += "=" }
        return Data(base64Encoded: padded)
    }

    /// RFC 3339 with or without fractional seconds (Go writes up to
    /// nanoseconds, which ISO8601DateFormatter can't read, so they are cut to
    /// milliseconds first).
    static func parseDate(_ value: Any?) -> Date? {
        guard var raw = value as? String, !raw.isEmpty else { return nil }
        if let dot = raw.firstIndex(of: "."),
           let end = raw[dot...].firstIndex(where: { !$0.isNumber && $0 != "." }) {
            let digits = raw[raw.index(after: dot)..<end]
            raw = String(raw[..<dot]) + "." + String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0) + String(raw[end...])
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }

    // MARK: - OAuth client

    /// Every OAuth client id and secret in `data`. Go packs string constants
    /// back to back with no separator, so they are matched by their exact
    /// shapes: `<digits>-<32 [a-z0-9]>.apps.googleusercontent.com` and
    /// `GOCSPX-<28 chars>`. Which secret belongs to which id is found by
    /// trying them against Google, once per app run.
    static func clientCandidates(in data: Data) -> (ids: [String], secrets: [String]) {
        var ids: [String] = []
        var secrets: [String] = []
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let count = buffer.count
            func scan(_ needle: String, _ body: (Int) -> Void) {
                let bytes = Array(needle.utf8)
                var offset = 0
                while offset < count {
                    guard let hit = memmem(base + offset, count - offset, bytes, bytes.count) else { break }
                    let index = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                    body(index)
                    offset = index + bytes.count
                }
            }
            func isLowerAlnum(_ b: UInt8) -> Bool { (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) }
            func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
            func isSecretChar(_ b: UInt8) -> Bool {
                isLowerAlnum(b) || (b >= 0x41 && b <= 0x5A) || b == 0x2D || b == 0x5F
            }
            scan(".apps.googleusercontent.com") { index in
                let hashStart = index - 32
                guard hashStart > 1, (hashStart..<index).allSatisfy({ isLowerAlnum(base[$0]) }),
                      base[hashStart - 1] == 0x2D else { return }
                var start = hashStart - 1
                while start > 0, isDigit(base[start - 1]), hashStart - 1 - start < 20 { start -= 1 }
                guard hashStart - 1 - start >= 6 else { return }
                let end = index + ".apps.googleusercontent.com".utf8.count
                let id = String(decoding: UnsafeBufferPointer(start: base + start, count: end - start), as: UTF8.self)
                if !ids.contains(id) { ids.append(id) }
            }
            scan("GOCSPX-") { index in
                let start = index + 7
                guard start + 28 <= count, (start..<start + 28).allSatisfy({ isSecretChar(base[$0]) }) else { return }
                let secret = String(decoding: UnsafeBufferPointer(start: base + index, count: 35), as: UTF8.self)
                if !secrets.contains(secret) { secrets.append(secret) }
            }
        }
        return (ids, secrets)
    }

    /// In-memory only: the client that renewed the grant, and the renewed
    /// token for the refresh token it came from.
    private actor Cache {
        var client: OAuthClient?
        var token: (refreshToken: String, accessToken: String, expiry: Date)?

        func setClient(_ client: OAuthClient?) { self.client = client }
        func setToken(refreshToken: String, accessToken: String, expiry: Date) {
            token = (refreshToken, accessToken, expiry)
        }
        func clearToken() { token = nil }
    }

    private static let cache = Cache()

    /// Tests: forget the renewed token and the client that renewed it.
    static func resetCache() async {
        await cache.setClient(nil)
        await cache.clearToken()
    }

    private enum RefreshAnswer {
        case token(String, expiresIn: TimeInterval)
        /// This client isn't the one the grant was issued to.
        case wrongClient
        case revoked
    }

    private static func renew(refreshToken: String, client: OAuthClient, deps: Deps) async throws -> RefreshAnswer {
        var request = URLRequest(url: URL(string: tokenEndpoint)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: client.id),
            URLQueryItem(name: "client_secret", value: client.secret),
        ]
        request.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let (data, response) = try await send(request, deps: deps)
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if response.statusCode == 200, let token = body["access_token"] as? String, !token.isEmpty {
            let expiresIn = (body["expires_in"] as? NSNumber)?.doubleValue ?? 3600
            return .token(token, expiresIn: expiresIn)
        }
        switch body["error"] as? String {
        case "invalid_grant": return .revoked
        case "invalid_client", "unauthorized_client": return .wrongClient
        default: throw FetchError.http(response.statusCode)
        }
    }

    /// A valid access token: the stored one, the one renewed earlier this run,
    /// or a newly renewed one. `force` skips the first two after a 401.
    private static func accessToken(for grant: Grant, force: Bool, deps: Deps) async throws -> String {
        let now = deps.now()
        if !force, let expiry = grant.expiry, expiry.timeIntervalSince(now) > expiryMargin {
            return grant.accessToken
        }
        guard let refreshToken = grant.refreshToken else {
            if force { throw FetchError.signedOut }
            return grant.accessToken
        }
        if !force, let cached = await cache.token, cached.refreshToken == refreshToken,
           cached.expiry.timeIntervalSince(now) > expiryMargin {
            return cached.accessToken
        }
        // The client that renewed this run goes first; the binaries are only
        // scanned (~200 MB, memory-mapped) when there is none or it stopped
        // working, e.g. after the user signed in with another client.
        if let known = await cache.client {
            if let token = try await renewAndCache(refreshToken: refreshToken, client: known, deps: deps) { return token }
            await cache.setClient(nil)
        }
        var clients: [OAuthClient] = []
        for binary in deps.binaries() {
            let found = clientCandidates(in: binary)
            for id in found.ids {
                for secret in found.secrets {
                    let client = OAuthClient(id: id, secret: secret)
                    if !clients.contains(client) { clients.append(client) }
                }
            }
        }
        for client in clients {
            if let token = try await renewAndCache(refreshToken: refreshToken, client: client, deps: deps) { return token }
        }
        throw FetchError.clientNotFound
    }

    /// The renewed token, nil when `client` isn't the grant's client, or
    /// signedOut when Google refuses the refresh token itself.
    private static func renewAndCache(refreshToken: String, client: OAuthClient, deps: Deps) async throws -> String? {
        switch try await renew(refreshToken: refreshToken, client: client, deps: deps) {
        case let .token(token, expiresIn):
            await cache.setClient(client)
            await cache.setToken(refreshToken: refreshToken, accessToken: token,
                                 expiry: deps.now().addingTimeInterval(expiresIn))
            return token
        case .revoked:
            await cache.clearToken()
            throw FetchError.signedOut
        case .wrongClient:
            return nil
        }
    }

    // MARK: - Fetch

    static func userAgent(version: String?) -> String {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "amd64"
        #endif
        return "antigravity/\(version ?? "2.35.2") darwin/\(arch)"
    }

    private static func post(_ path: String, body: [String: Any], token: String, deps: Deps) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: "\(endpoint):\(path)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent(version: deps.appVersion()), forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return try await send(request, deps: deps)
    }

    private static func send(_ request: URLRequest, deps: Deps) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await deps.fetch(request)
        } catch let error as FetchError {
            throw error
        } catch {
            throw FetchError.network(AntigravitySubscriptionService.sanitizeForLog(error.localizedDescription))
        }
    }

    static func planFromLoadCodeAssist(_ body: [String: Any]) -> String? {
        for key in ["paidTier", "currentTier"] {
            if let tier = body[key] as? [String: Any],
               let name = (tier["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                return name
            }
        }
        return nil
    }

    static func fetch(deps: Deps = .live) async throws -> AntigravityUsage {
        guard let raw = await deps.readKeychain(), let grant = parseGrant(raw) else { throw FetchError.noGrant }
        var token = try await accessToken(for: grant, force: false, deps: deps)
        let assistBody: [String: Any] = ["metadata": ["ideType": "ANTIGRAVITY", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"]]
        var (assistData, assistResponse) = try await post("loadCodeAssist", body: assistBody, token: token, deps: deps)
        if assistResponse.statusCode == 401 {
            // Revoked early, or the clock is off: renew once and retry.
            token = try await accessToken(for: grant, force: true, deps: deps)
            (assistData, assistResponse) = try await post("loadCodeAssist", body: assistBody, token: token, deps: deps)
        }
        guard (200..<300).contains(assistResponse.statusCode) else {
            if assistResponse.statusCode == 401 { throw FetchError.signedOut }
            throw FetchError.http(assistResponse.statusCode)
        }
        let assist = (try? JSONSerialization.jsonObject(with: assistData)) as? [String: Any] ?? [:]
        let project = (assist["cloudaicompanionProject"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let (quotaData, quotaResponse) = try await post(
            "retrieveUserQuotaSummary", body: project.map { ["project": $0] } ?? [:], token: token, deps: deps)
        guard (200..<300).contains(quotaResponse.statusCode) else { throw FetchError.http(quotaResponse.statusCode) }
        let parsed = try? JSONSerialization.jsonObject(with: quotaData)
        let windows = AntigravitySubscriptionService.decodeSummary(parsed)
        guard !windows.isEmpty else { throw FetchError.http(quotaResponse.statusCode) }
        return AntigravityUsage(
            details: windows.sorted { $0.usedPercent > $1.usedPercent },
            plan: planFromLoadCodeAssist(assist),
            fetchedAt: deps.now(),
            groups: AntigravitySubscriptionService.decodeGroups(parsed),
            source: .remote
        )
    }
}

/// Where Antigravity is installed on this Mac.
enum AntigravityInstall {
    static let appPaths = [
        "/Applications/Antigravity.app",
        NSHomeDirectory() + "/Applications/Antigravity.app",
    ]

    static func appVersion() -> String? {
        for app in appPaths {
            if let info = NSDictionary(contentsOfFile: app + "/Contents/Info.plist"),
               let version = info["CFBundleShortVersionString"] as? String, !version.isEmpty {
                return version
            }
        }
        return nil
    }

    /// The `agy` CLI, if installed.
    static func agyPath() -> String? {
        let candidates = [
            NSHomeDirectory() + "/.local/bin/agy",
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Binaries that embed Antigravity's OAuth client: the app's language
    /// server first, then the CLI (the symlink resolved).
    static func oauthBinaryPaths() -> [String] {
        var paths = appPaths.map { $0 + "/Contents/Resources/bin/language_server" }
        if let agy = agyPath() {
            paths.append((agy as NSString).resolvingSymlinksInPath)
        }
        return paths.filter { FileManager.default.fileExists(atPath: $0) }
    }
}
