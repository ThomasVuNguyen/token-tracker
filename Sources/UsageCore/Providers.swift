import Foundation

public protocol UsageProvider: Sendable {
    func load() async -> ProviderSnapshot
}

public struct ClaudeProvider: UsageProvider {
    public init() {}

    public func load() async -> ProviderSnapshot {
        do {
            for session in Self.sessions() {
                do {
                    return try await Self.fetch(token: session.token, plan: session.plan)
                } catch let failure as UsageFailure {
                    guard case .expired = failure else { throw failure }
                }
            }
            if let renewed = try? await Self.refreshKeychain() {
                return try await Self.fetch(token: renewed.token, plan: renewed.plan)
            }
            throw Self.sessions().isEmpty && Self.keychainOAuth() == nil
                ? UsageFailure.signedOut("Claude Code")
                : UsageFailure.expired("Claude Code")
        } catch let failure as UsageFailure {
            return Self.failure(failure)
        } catch {
            return Self.failure(.signedOut("Claude Code"))
        }
    }

    private struct Session {
        var token: String
        var expiry: Date
        var plan: String?
    }

    private static let service = "Claude Code-credentials"

    /// Live access tokens, newest expiry first. The Claude app's session is included
    /// because that is what stays signed in while the CLI keychain token ages out.
    private static func sessions() -> [Session] {
        var found: [Session] = []
        if let oauth = keychainOAuth(), let token = usableAccess(oauth) {
            found.append(Session(
                token: token,
                expiry: Dates.parse(oauth["expiresAt"]) ?? .distantFuture,
                plan: planLabel(
                    subscription: JSONValue.string(oauth["subscriptionType"]),
                    tier: JSONValue.string(oauth["rateLimitTier"])
                )
            ))
        }
        let soon = Date().addingTimeInterval(60)
        for login in ClaudeDesktopCredentials.logins() {
            let expiry = login.expiry ?? .distantFuture
            guard expiry > soon else { continue }
            found.append(Session(
                token: login.accessToken,
                expiry: expiry,
                plan: planLabel(subscription: login.subscription, tier: login.tier)
            ))
        }
        return found.sorted { $0.expiry > $1.expiry }
    }

    private static func keychainOAuth() -> [String: Any]? {
        guard let raw = try? Credentials.keychainPassword(service: service, account: NSUserName()),
              let stored = try? JSONValue.object(from: Data(raw.utf8)) else { return nil }
        return JSONValue.dictionary(stored["claudeAiOauth"])
    }

    private static func refreshKeychain() async throws -> Session {
        let account = NSUserName()
        guard let oauth = keychainOAuth() else { throw UsageFailure.signedOut("Claude Code") }
        let plan = planLabel(
            subscription: JSONValue.string(oauth["subscriptionType"]),
            tier: JSONValue.string(oauth["rateLimitTier"])
        )
        guard let refreshToken = JSONValue.string(oauth["refreshToken"]), !refreshToken.isEmpty else {
            throw UsageFailure.expired("Claude Code")
        }
        if let refreshExpiry = Dates.parse(oauth["refreshTokenExpiresAt"]), refreshExpiry < Date() {
            throw UsageFailure.expired("Claude Code")
        }
        let scopes = JSONValue.array(oauth["scopes"])?.compactMap { $0 as? String } ?? []
        let refreshed = try await ClaudeOAuth.refresh(refreshToken: refreshToken, scopes: scopes)
        _ = try save(account: account, expectedRefresh: refreshToken, refreshed: refreshed)
        return Session(token: refreshed.accessToken, expiry: refreshed.expiresAt, plan: plan)
    }

    private static func usableAccess(_ oauth: [String: Any]) -> String? {
        guard let token = JSONValue.string(oauth["accessToken"]), !token.isEmpty else { return nil }
        if let expiry = Dates.parse(oauth["expiresAt"]), expiry <= Date().addingTimeInterval(60) {
            return nil
        }
        return token
    }

    private static func save(account: String, expectedRefresh: String, refreshed: OAuthRefresh) throws -> Bool {
        var lastError: Error?
        for _ in 0..<3 {
            do {
                return try Credentials.updateJSON(
                    service: service,
                    account: account,
                    decode: { try JSONValue.object(from: Data($0.utf8)) },
                    encode: { object in
                        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
                    },
                    mutate: { root in
                        guard var oauth = JSONValue.dictionary(root["claudeAiOauth"]),
                              JSONValue.string(oauth["refreshToken"]) == expectedRefresh else { return false }
                        oauth["accessToken"] = refreshed.accessToken
                        oauth["refreshToken"] = refreshed.refreshToken
                        oauth["expiresAt"] = Milliseconds.since1970(refreshed.expiresAt)
                        if let refreshExpiresAt = refreshed.refreshExpiresAt {
                            oauth["refreshTokenExpiresAt"] = Milliseconds.since1970(refreshExpiresAt)
                        }
                        if let scopes = refreshed.scopes, !scopes.isEmpty {
                            oauth["scopes"] = scopes
                        }
                        root["claudeAiOauth"] = oauth
                        return true
                    }
                )
            } catch {
                lastError = error
            }
        }
        throw lastError ?? KeychainError.missing
    }

    private static func fetch(token: String, plan: String?) async throws -> ProviderSnapshot {
        let response = try await HTTP.send(HTTP.request(
            URL(string: "https://api.anthropic.com/api/oauth/usage")!,
            method: "GET",
            headers: [
                "Authorization": "Bearer \(token)",
                "Accept": "application/json",
                "anthropic-beta": "oauth-2025-04-20",
                "User-Agent": "claude-cli/2.1.294 (external, cli)",
            ]
        ))
        guard (200..<300).contains(response.status) else {
            throw response.status == 401
                ? UsageFailure.expired("Claude Code")
                : UsageFailure.http(provider: "Claude", status: response.status)
        }
        return try parse(response.body, plan: plan)
    }

    public static func parse(_ data: Data, plan: String? = nil) throws -> ProviderSnapshot {
        let body = try JSONValue.object(from: data)
        var meters: [Meter] = []
        if let limits = JSONValue.array(body["limits"]) {
            for entry in limits {
                guard let limit = entry as? [String: Any],
                      let kind = JSONValue.string(limit["kind"]),
                      let percent = JSONValue.double(limit["percent"]) else { continue }
                let label: String
                switch kind {
                case "session":
                    label = "Session"
                case "weekly_all":
                    label = "Weekly"
                case "weekly_scoped":
                    let scope = JSONValue.dictionary(limit["scope"])
                    let model = JSONValue.dictionary(scope?["model"])
                    label = JSONValue.string(model?["display_name"]) ?? "Model"
                default:
                    continue
                }
                meters.append(Meter(
                    id: "claude-\(kind)-\(label)",
                    label: label,
                    remaining: remainingFraction(usedPercent: percent),
                    detail: Dates.resetDetail(Dates.parse(limit["resets_at"]))
                ))
            }
        }
        if meters.isEmpty {
            appendLegacy(body["five_hour"], id: "session", label: "Session", to: &meters)
            appendLegacy(body["seven_day"], id: "weekly", label: "Weekly", to: &meters)
        }
        return ProviderSnapshot(
            id: "claude",
            name: "Claude",
            menuLabel: "C",
            plan: plan,
            meters: meters
        )
    }

    private static func appendLegacy(_ value: Any?, id: String, label: String, to meters: inout [Meter]) {
        guard let window = JSONValue.dictionary(value),
              let used = JSONValue.double(window["utilization"]) else { return }
        let percent = used <= 1 ? used * 100 : used
        meters.append(Meter(
            id: "claude-\(id)",
            label: label,
            remaining: remainingFraction(usedPercent: percent),
            detail: Dates.resetDetail(Dates.parse(window["resets_at"]))
        ))
    }

    static func planLabel(subscription: String?, tier: String?) -> String? {
        let name: String
        switch subscription?.lowercased() {
        case "max": name = "Max"
        case "pro": name = "Pro"
        case "team": name = "Team"
        case "enterprise": name = "Enterprise"
        default:
            name = subscription?.capitalized ?? ""
        }
        let multiplier = tier.flatMap { text -> String? in
            guard let range = text.range(of: #"\d+x"#, options: .regularExpression) else { return nil }
            return String(text[range])
        }
        if name.isEmpty { return multiplier }
        if let multiplier, name != "Enterprise" {
            return "\(name) · \(multiplier)"
        }
        return name
    }

    private static func failure(_ failure: UsageFailure) -> ProviderSnapshot {
        ProviderSnapshot(id: "claude", name: "Claude", menuLabel: "C", note: failure.description)
    }
}

public struct CodexProvider: UsageProvider {
    public init() {}

    public func load() async -> ProviderSnapshot {
        do {
            let data = try Credentials.homeFile(".codex/auth.json")
            let stored = try JSONValue.object(from: data)
            guard let tokens = JSONValue.dictionary(stored["tokens"]),
                  let accessToken = JSONValue.string(tokens["access_token"]), !accessToken.isEmpty else {
                throw UsageFailure.signedOut("Codex")
            }
            let accountID = JSONValue.string(tokens["account_id"])
            var headers = [
                "Authorization": "Bearer \(accessToken)",
                "Accept": "application/json",
                "User-Agent": "codex-cli",
            ]
            if let accountID, !accountID.isEmpty {
                headers["ChatGPT-Account-Id"] = accountID
            }
            let response = try await HTTP.send(HTTP.request(
                URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
                method: "GET",
                headers: headers
            ))
            guard (200..<300).contains(response.status) else {
                throw response.status == 401
                    ? UsageFailure.expired("Codex")
                    : UsageFailure.http(provider: "Codex", status: response.status)
            }
            return try Self.parse(response.body)
        } catch let failure as UsageFailure {
            return Self.empty(failure.description)
        } catch {
            return Self.empty("Sign in to Codex")
        }
    }

    public static func parse(_ data: Data) throws -> ProviderSnapshot {
        let body = try JSONValue.object(from: data)
        let rateLimit = JSONValue.dictionary(body["rate_limit"])
        var meters: [Meter] = []
        for slot in ["primary_window", "secondary_window"] {
            guard let window = JSONValue.dictionary(rateLimit?[slot]),
                  let used = JSONValue.double(window["used_percent"]) else { continue }
            let seconds = JSONValue.double(window["limit_window_seconds"]) ?? 0
            let label = seconds >= 86_400 ? "Weekly" : "Session"
            meters.append(Meter(
                id: "codex-\(slot)",
                label: label,
                remaining: remainingFraction(usedPercent: used),
                detail: Dates.resetDetail(Dates.parse(window["reset_at"]))
            ))
        }
        if let credits = JSONValue.dictionary(body["credits"]),
           JSONValue.double(credits["balance"]) != nil,
           credits["has_credits"] as? Bool != false,
           let balance = JSONValue.double(credits["balance"]) {
            let rounded = balance >= 10 ? String(Int(balance.rounded())) : String(format: "%.1f", balance)
            meters.append(Meter(
                id: "codex-credits",
                label: "Credits",
                remaining: nil,
                detail: "\(rounded) left"
            ))
        }
        return ProviderSnapshot(
            id: "codex",
            name: "Codex",
            menuLabel: "X",
            plan: JSONValue.string(body["plan_type"])?.capitalized,
            meters: meters
        )
    }

    private static func empty(_ note: String) -> ProviderSnapshot {
        ProviderSnapshot(id: "codex", name: "Codex", menuLabel: "X", note: note)
    }
}

public struct CursorProvider: UsageProvider {
    public init() {}

    public func load() async -> ProviderSnapshot {
        do {
            let token = try Credentials.keychainPassword(service: "cursor-access-token")
            guard token.hasPrefix("eyJ") else { throw UsageFailure.expired("Cursor") }
            let response = try await HTTP.send(HTTP.request(
                URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!,
                method: "POST",
                headers: [
                    "Authorization": "Bearer \(token)",
                    "Content-Type": "application/json",
                    "Connect-Protocol-Version": "1",
                ],
                body: Data("{}".utf8)
            ))
            guard (200..<300).contains(response.status) else {
                throw response.status == 401
                    ? UsageFailure.expired("Cursor")
                    : UsageFailure.http(provider: "Cursor", status: response.status)
            }
            var snapshot = try Self.parse(response.body)
            snapshot.plan = Self.membershipPlan() ?? snapshot.plan
            return snapshot
        } catch let failure as UsageFailure {
            return Self.empty(failure.description)
        } catch {
            return Self.empty("Sign in to Cursor")
        }
    }

    private static func membershipPlan() -> String? {
        let database = URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: "Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            database.path,
            "SELECT value FROM ItemTable WHERE key='cursorAuth/stripeMembershipType';",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0, !text.isEmpty else { return nil }
        return text.capitalized
    }

    public static func parse(_ data: Data) throws -> ProviderSnapshot {
        let body = try JSONValue.object(from: data)
        let usage = JSONValue.dictionary(body["planUsage"]) ?? [:]
        var meters: [Meter] = []
        let cycleEnd = Dates.resetDetail(Dates.parse(body["billingCycleEnd"]))
            .replacingOccurrences(of: "resets", with: "cycle ends")
        if let auto = JSONValue.double(usage["autoPercentUsed"]) {
            meters.append(Meter(
                id: "cursor-auto",
                label: "Auto",
                remaining: remainingFraction(usedPercent: auto),
                detail: cycleEnd
            ))
        }
        if let api = JSONValue.double(usage["apiPercentUsed"]) {
            meters.append(Meter(
                id: "cursor-api",
                label: "API",
                remaining: remainingFraction(usedPercent: api),
                detail: cycleEnd
            ))
        }
        if meters.isEmpty, let total = JSONValue.double(usage["totalPercentUsed"]) {
            meters.append(Meter(
                id: "cursor-total",
                label: "Included",
                remaining: remainingFraction(usedPercent: total),
                detail: cycleEnd
            ))
        }
        let note: String?
        if let spent = JSONValue.double(usage["includedSpend"]),
           let limit = JSONValue.double(usage["limit"]), limit > 0 {
            note = "Included \(Self.dollars(spent)) of \(Self.dollars(limit))"
        } else {
            note = nil
        }
        return ProviderSnapshot(
            id: "cursor",
            name: "Cursor",
            menuLabel: "Cu",
            plan: "Pro",
            meters: meters,
            note: note
        )
    }

    private static func dollars(_ cents: Double) -> String {
        String(format: "$%.0f", (cents / 100).rounded())
    }

    private static func empty(_ note: String) -> ProviderSnapshot {
        ProviderSnapshot(id: "cursor", name: "Cursor", menuLabel: "Cu", note: note)
    }
}

public struct AntigravityProvider: UsageProvider {
    public init() {}

    public func load() async -> ProviderSnapshot {
        do {
            let token = try await Self.accessToken()
            do {
                return try await Self.fetch(token: token)
            } catch let failure as UsageFailure {
                guard case .expired = failure else { throw failure }
                return try await Self.fetch(token: try await Self.accessToken(forceRefresh: true))
            }
        } catch let failure as UsageFailure {
            return Self.empty(failure.description)
        } catch {
            return Self.empty("Sign in to Antigravity")
        }
    }

    private static let service = "gemini"
    private static let account = "antigravity"

    private static func accessToken(forceRefresh: Bool = false) async throws -> String {
        let raw = try Credentials.keychainPassword(service: service, account: account)
        let stored = try GoogleTokenFile.object(from: raw)
        let token = try GoogleTokenFile.token(in: stored)
        let stillValid = token.expiry.map { $0 > Date().addingTimeInterval(60) } ?? true
        if !forceRefresh, stillValid {
            return token.accessToken
        }
        guard let refreshToken = token.refreshToken, !refreshToken.isEmpty else {
            throw UsageFailure.expired("Antigravity")
        }
        let refreshed = try await AntigravityOAuth.refresh(refreshToken: refreshToken)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let saved = try save(expectedRefresh: refreshToken, refreshed: refreshed, expiry: formatter.string(from: refreshed.expiresAt))
        if saved { return refreshed.accessToken }
        let latest = try GoogleTokenFile.decode(try Credentials.keychainPassword(service: service, account: account))
        return latest.accessToken
    }

    private static func save(expectedRefresh: String, refreshed: OAuthRefresh, expiry: String) throws -> Bool {
        var lastError: Error?
        for _ in 0..<3 {
            do {
                return try Credentials.updateJSON(
                    service: service,
                    account: account,
                    decode: { try GoogleTokenFile.object(from: $0) },
                    encode: { try GoogleTokenFile.wrap($0) },
                    mutate: { root in
                        guard var token = JSONValue.dictionary(root["token"]),
                              JSONValue.string(token["refresh_token"]) == expectedRefresh else { return false }
                        token["access_token"] = refreshed.accessToken
                        token["refresh_token"] = refreshed.refreshToken
                        token["expiry"] = expiry
                        token["expires_in"] = Int(refreshed.expiresAt.timeIntervalSinceNow.rounded())
                        root["token"] = token
                        return true
                    }
                )
            } catch {
                lastError = error
            }
        }
        throw lastError ?? KeychainError.missing
    }

    private static func fetch(token: String) async throws -> ProviderSnapshot {
        let headers = [
            "Authorization": "Bearer \(token)",
            "Accept": "application/json",
            "Content-Type": "application/json",
            "User-Agent": "antigravity/2.24.0 (aidev_client; os_type=darwin; arch=arm64)",
        ]
        async let planResponse = HTTP.send(HTTP.request(
            URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!,
            method: "POST",
            headers: headers,
            body: Data(#"{"metadata":{"ideType":"ANTIGRAVITY","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}}"#.utf8)
        ))
        async let quotaResponse = HTTP.send(HTTP.request(
            URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!,
            method: "POST",
            headers: headers,
            body: Data("{}".utf8)
        ))
        let quota = try await quotaResponse
        guard (200..<300).contains(quota.status) else {
            throw quota.status == 401
                ? UsageFailure.expired("Antigravity")
                : UsageFailure.http(provider: "Antigravity", status: quota.status)
        }
        let plan = try? await planResponse
        let planName = plan.flatMap { response -> String? in
            guard (200..<300).contains(response.status),
                  let body = try? JSONValue.object(from: response.body) else { return nil }
            let paid = JSONValue.dictionary(body["paidTier"])
            return JSONValue.string(paid?["name"])
        }
        return try Self.parse(quota.body, plan: planName)
    }

    public static func parse(_ data: Data, plan: String? = nil) throws -> ProviderSnapshot {
        let body = try JSONValue.object(from: data)
        var seen: [String: Meter] = [:]
        for group in JSONValue.array(body["groups"]) ?? [] {
            guard let group = group as? [String: Any] else { continue }
            for bucket in JSONValue.array(group["buckets"]) ?? [] {
                guard let bucket = bucket as? [String: Any],
                      let fraction = JSONValue.double(bucket["remainingFraction"]) else { continue }
                let display = JSONValue.string(bucket["displayName"]) ?? "Models"
                let label = Self.poolLabel(display)
                let meter = Meter(
                    id: "antigravity-\(label)",
                    label: label,
                    remaining: min(1, max(0, fraction)),
                    detail: Dates.resetDetail(Dates.parse(bucket["resetTime"]))
                )
                if let existing = seen[label], let left = existing.remaining, left <= fraction {
                    continue
                }
                seen[label] = meter
            }
        }
        let order = ["Gemini", "Claude / GPT"]
        let meters = seen.values.sorted { lhs, rhs in
            (order.firstIndex(of: lhs.label) ?? 9, lhs.label) < (order.firstIndex(of: rhs.label) ?? 9, rhs.label)
        }
        return ProviderSnapshot(
            id: "antigravity",
            name: "Antigravity",
            menuLabel: "AG",
            plan: plan,
            meters: meters
        )
    }

    static func poolLabel(_ displayName: String) -> String {
        let name = displayName.lowercased()
        if name.contains("gemini") { return "Gemini" }
        if name.contains("claude") || name.contains("gpt") { return "Claude / GPT" }
        return displayName
    }

    private static func empty(_ note: String) -> ProviderSnapshot {
        ProviderSnapshot(id: "antigravity", name: "Antigravity", menuLabel: "AG", note: note)
    }
}

public struct UsageTracker: Sendable {
    public var providers: [any UsageProvider]

    public init(providers: [any UsageProvider] = [
        ClaudeProvider(),
        CodexProvider(),
        CursorProvider(),
        AntigravityProvider(),
    ]) {
        self.providers = providers
    }

    public func refresh() async -> [ProviderSnapshot] {
        await withTaskGroup(of: (Int, ProviderSnapshot).self) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask { (index, await provider.load()) }
            }
            var rows: [(Int, ProviderSnapshot)] = []
            for await row in group {
                rows.append(row)
            }
            return rows.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}

