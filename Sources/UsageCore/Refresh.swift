import Foundation

struct OAuthRefresh: Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var refreshExpiresAt: Date?
    var scopes: [String]?
}

enum ClaudeOAuth {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let defaultScopes = [
        "user:profile",
        "user:inference",
        "user:sessions:claude_code",
        "user:mcp_servers",
        "user:file_upload",
        "user:plugins",
    ]

    static func refresh(refreshToken: String, scopes: [String]) async throws -> OAuthRefresh {
        let requested = scopes.isEmpty ? defaultScopes : scopes
        let body = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
            "scope": requested.joined(separator: " "),
        ])
        let response = try await HTTP.send(HTTP.request(
            URL(string: "https://platform.claude.com/v1/oauth/token")!,
            method: "POST",
            headers: [
                "Content-Type": "application/json",
                "Accept": "application/json",
                "User-Agent": "claude-cli/2.1.318 (external, cli)",
            ],
            body: body
        ))
        guard (200..<300).contains(response.status) else {
            throw UsageFailure.expired("Claude Code")
        }
        return try decode(response.body, fallbackRefresh: refreshToken, provider: "Claude Code")
    }
}

enum AntigravityOAuth {
    static let clientID = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"

    static func refresh(refreshToken: String) async throws -> OAuthRefresh {
        let secrets = clientSecrets()
        guard !secrets.isEmpty else { throw UsageFailure.expired("Antigravity") }
        for secret in secrets {
            let response = try await HTTP.send(HTTP.request(
                URL(string: "https://oauth2.googleapis.com/token")!,
                method: "POST",
                headers: ["Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"],
                body: HTTP.form([
                    "grant_type": "refresh_token",
                    "refresh_token": refreshToken,
                    "client_id": clientID,
                    "client_secret": secret,
                ])
            ))
            if (200..<300).contains(response.status) {
                return try decode(response.body, fallbackRefresh: refreshToken, provider: "Antigravity")
            }
            let error = try? JSONValue.object(from: response.body)
            if JSONValue.string(error?["error"]) == "invalid_grant" {
                throw UsageFailure.expired("Antigravity")
            }
        }
        throw UsageFailure.expired("Antigravity")
    }

    /// Client secrets ship inside the Antigravity language server. They are not stored in this repo.
    static func clientSecrets() -> [String] {
        let url = URL(fileURLWithPath: "/Applications/Antigravity.app/Contents/Resources/bin/language_server")
        guard let data = try? Data(contentsOf: url) else { return [] }
        let needle = Data("GOCSPX-".utf8)
        var secrets: [String] = []
        var start = data.startIndex
        while let range = data.range(of: needle, in: start..<data.endIndex) {
            let end = data.index(range.lowerBound, offsetBy: 35, limitedBy: data.endIndex) ?? data.endIndex
            let slice = data[range.lowerBound..<end]
            if slice.count == 35,
               let secret = String(data: slice, encoding: .utf8),
               secret.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) {
                secrets.append(secret)
            }
            start = range.upperBound
        }
        return secrets
    }
}

private func decode(_ data: Data, fallbackRefresh: String, provider: String) throws -> OAuthRefresh {
    let object = try JSONValue.object(from: data)
    guard let accessToken = JSONValue.string(object["access_token"]), !accessToken.isEmpty,
          let expiresIn = JSONValue.double(object["expires_in"]) else {
        throw UsageFailure.badResponse(provider)
    }
    let refreshExpires = JSONValue.double(object["refresh_token_expires_in"]).map {
        Date().addingTimeInterval($0)
    }
    let scopes = JSONValue.string(object["scope"])?
        .split(separator: " ")
        .map(String.init)
    return OAuthRefresh(
        accessToken: accessToken,
        refreshToken: JSONValue.string(object["refresh_token"]) ?? fallbackRefresh,
        expiresAt: Date().addingTimeInterval(expiresIn),
        refreshExpiresAt: refreshExpires,
        scopes: scopes
    )
}

enum Milliseconds {
    static func since1970(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 * 1000).rounded())
    }
}
