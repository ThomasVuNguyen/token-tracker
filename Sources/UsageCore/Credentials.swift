import Foundation

enum KeychainError: Error {
    case missing
}

enum Credentials {
    static func keychainPassword(service: String, account: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        var arguments = ["find-generic-password", "-s", service, "-w"]
        if let account {
            arguments += ["-a", account]
        }
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0, !text.isEmpty else {
            throw KeychainError.missing
        }
        return text
    }

    static func setKeychainPassword(_ password: String, service: String, account: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["add-generic-password", "-U", "-s", service, "-a", account, "-w", password]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw KeychainError.missing }
    }

    /// Rewrites one JSON keychain item. Returns false when `mutate` declines, so a newer sign-in is left alone.
    static func updateJSON(
        service: String,
        account: String,
        decode: (String) throws -> [String: Any],
        encode: ([String: Any]) throws -> String,
        mutate: (inout [String: Any]) -> Bool
    ) throws -> Bool {
        let raw = try keychainPassword(service: service, account: account)
        var object = try decode(raw)
        guard mutate(&object) else { return false }
        try setKeychainPassword(try encode(object), service: service, account: account)
        return true
    }

    static func homeFile(_ path: String) throws -> Data {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appending(path: path)
        return try Data(contentsOf: url)
    }
}

struct GoogleAccessToken: Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiry: Date?
}

enum GoogleTokenFile {
    static let prefix = "go-keyring-base64:"

    static func object(from raw: String) throws -> [String: Any] {
        let jsonText: String
        if raw.hasPrefix(prefix) {
            guard let data = Data(base64Encoded: String(raw.dropFirst(prefix.count))),
                  let text = String(data: data, encoding: .utf8) else {
                throw UsageFailure.badResponse("Antigravity")
            }
            jsonText = text
        } else {
            jsonText = raw
        }
        return try JSONValue.object(from: Data(jsonText.utf8))
    }

    static func wrap(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return prefix + data.base64EncodedString()
    }

    static func token(in object: [String: Any]) throws -> GoogleAccessToken {
        let token = JSONValue.dictionary(object["token"]) ?? object
        guard let accessToken = JSONValue.string(token["access_token"]), !accessToken.isEmpty else {
            throw UsageFailure.signedOut("Antigravity")
        }
        return GoogleAccessToken(
            accessToken: accessToken,
            refreshToken: JSONValue.string(token["refresh_token"]),
            expiry: Dates.parse(token["expiry"])
        )
    }

    static func decode(_ raw: String) throws -> GoogleAccessToken {
        try token(in: object(from: raw))
    }
}
