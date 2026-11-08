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

    static func homeFile(_ path: String) throws -> Data {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appending(path: path)
        return try Data(contentsOf: url)
    }
}

struct GoogleAccessToken: Sendable {
    var accessToken: String
    var expiry: Date?
}

enum GoogleTokenFile {
    static func decode(_ raw: String) throws -> GoogleAccessToken {
        let jsonText: String
        let prefix = "go-keyring-base64:"
        if raw.hasPrefix(prefix) {
            guard let data = Data(base64Encoded: String(raw.dropFirst(prefix.count))),
                  let text = String(data: data, encoding: .utf8) else {
                throw UsageFailure.badResponse("Antigravity")
            }
            jsonText = text
        } else {
            jsonText = raw
        }
        let object = try JSONValue.object(from: Data(jsonText.utf8))
        let token = JSONValue.dictionary(object["token"]) ?? object
        guard let accessToken = JSONValue.string(token["access_token"]), !accessToken.isEmpty else {
            throw UsageFailure.signedOut("Antigravity")
        }
        return GoogleAccessToken(accessToken: accessToken, expiry: Dates.parse(token["expiry"]))
    }
}
