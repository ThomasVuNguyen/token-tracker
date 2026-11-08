import CommonCrypto
import Foundation

/// The Claude app keeps its own sign-in, separate from the `claude` CLI keychain item.
enum ClaudeDesktopCredentials {
    struct Login {
        var accessToken: String
        var expiry: Date?
        var subscription: String?
        var tier: String?
    }

    static func logins() -> [Login] {
        guard let raw = try? Credentials.homeFile("Library/Application Support/Claude/config.json"),
              let config = try? JSONValue.object(from: raw),
              let sealed = JSONValue.string(config["oauth:tokenCacheV2"]),
              let opened = try? decrypt(sealed),
              let cache = try? JSONValue.object(from: opened) else { return [] }
        return cache.values.compactMap(login)
    }

    private static func login(_ value: Any) -> Login? {
        guard let entry = value as? [String: Any],
              let token = JSONValue.string(entry["token"]), !token.isEmpty else { return nil }
        return Login(
            accessToken: token,
            expiry: Dates.parse(entry["expiresAt"]),
            subscription: JSONValue.string(entry["subscriptionType"]),
            tier: JSONValue.string(entry["rateLimitTier"])
        )
    }

    /// Chromium safeStorage on macOS: PBKDF2-SHA1 over the "Claude Safe Storage" key, then AES-128-CBC.
    private static func decrypt(_ sealed: String) throws -> Data {
        let password = try Credentials.keychainPassword(service: "Claude Safe Storage", account: "Claude Key")
        guard var data = Data(base64Encoded: sealed), data.starts(with: Data("v10".utf8)) else {
            throw KeychainError.missing
        }
        data.removeFirst(3)
        let key = try derivedKey(password)
        let iv = Array(repeating: UInt8(ascii: " "), count: 16)
        let keyCount = key.count
        let dataCount = data.count
        var output = Data(count: dataCount + kCCBlockSizeAES128)
        let outputCount = output.count
        var moved = 0
        let status: CCCryptorStatus = key.withUnsafeBytes { keyBytes in
            data.withUnsafeBytes { dataBytes in
                iv.withUnsafeBytes { ivBytes in
                    output.withUnsafeMutableBytes { outBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, keyCount,
                            ivBytes.baseAddress,
                            dataBytes.baseAddress, dataCount,
                            outBytes.baseAddress, outputCount,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw KeychainError.missing }
        output.removeSubrange(moved..<output.count)
        return output
    }

    private static func derivedKey(_ password: String) throws -> Data {
        var key = Data(count: 16)
        let keyCount = key.count
        let salt = Array("saltysalt".utf8)
        let saltCount = salt.count
        let status: CCStatus = password.withCString { passwordPointer in
            salt.withUnsafeBytes { saltBytes in
                key.withUnsafeMutableBytes { keyBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordPointer,
                        strlen(passwordPointer),
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        saltCount,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        keyBytes.bindMemory(to: UInt8.self).baseAddress,
                        keyCount
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw KeychainError.missing }
        return key
    }
}
