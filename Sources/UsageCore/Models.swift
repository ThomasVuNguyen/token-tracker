import Foundation

public struct Meter: Identifiable, Sendable, Equatable {
    public var id: String
    public var label: String
    /// Remaining allowance from 0 to 1. Absent for counts such as credits.
    public var remaining: Double?
    public var detail: String

    public init(id: String, label: String, remaining: Double?, detail: String) {
        self.id = id
        self.label = label
        self.remaining = remaining
        self.detail = detail
    }

    public var remainingPercent: Int? {
        guard let remaining else { return nil }
        return Int((min(1, max(0, remaining)) * 100).rounded())
    }
}

public struct ProviderSnapshot: Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var menuLabel: String
    public var plan: String?
    public var meters: [Meter]
    public var note: String?
    public var updatedAt: Date

    public init(
        id: String,
        name: String,
        menuLabel: String,
        plan: String? = nil,
        meters: [Meter] = [],
        note: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.menuLabel = menuLabel
        self.plan = plan
        self.meters = meters
        self.note = note
        self.updatedAt = updatedAt
    }

    public var summary: String {
        var lines = ["\(name)\(plan.map { " · \($0)" } ?? "")"]
        if meters.isEmpty, let note {
            lines.append("  \(note)")
        }
        for meter in meters {
            let value = meter.remainingPercent.map { "\($0)% left" } ?? meter.detail
            let extra = meter.remainingPercent == nil ? "" : "  \(meter.detail)"
            lines.append("  \(meter.label): \(value)\(extra)")
        }
        if !meters.isEmpty, let note {
            lines.append("  \(note)")
        }
        return lines.joined(separator: "\n")
    }
}

public enum UsageFailure: Error, CustomStringConvertible, Sendable {
    case signedOut(String)
    case expired(String)
    case http(provider: String, status: Int)
    case badResponse(String)

    public var description: String {
        switch self {
        case .signedOut(let provider):
            "Sign in to \(provider)"
        case .expired(let provider):
            "Sign-in expired. Open \(provider)."
        case .http(let provider, let status):
            "\(provider) didn't answer (HTTP \(status))"
        case .badResponse(let provider):
            "\(provider) returned something unexpected"
        }
    }
}

enum Dates {
    static func parse(_ value: Any?) -> Date? {
        switch value {
        case let number as NSNumber:
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return fromUnix(number.doubleValue)
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let number = Double(trimmed), number > 1_000_000_000 {
                return fromUnix(number)
            }
            return fromISO(trimmed)
        default:
            return nil
        }
    }

    static func fromUnix(_ raw: Double) -> Date {
        let seconds = raw > 10_000_000_000 ? raw / 1000 : raw
        return Date(timeIntervalSince1970: seconds)
    }

    static func fromISO(_ text: String) -> Date? {
        for options: ISO8601DateFormatter.Options in [
            [.withInternetDateTime, .withFractionalSeconds],
            [.withInternetDateTime],
        ] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: text) {
                return date
            }
        }
        return nil
    }

    static func resetDetail(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let seconds = date.timeIntervalSince(now)
        if seconds <= 60 { return "resets now" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds > 86_400 ? [.day, .hour] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        let body = formatter.string(from: seconds) ?? ""
        return "resets in \(body)"
    }
}

enum JSONValue {
    static func object(from data: Data) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: data)
        guard let object = value as? [String: Any] else { throw UsageFailure.badResponse("response") }
        return object
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as Double:
            return number
        case let number as Int:
            return Double(number)
        case let number as NSNumber:
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return number.doubleValue
        case let text as String:
            return Double(text)
        default:
            return nil
        }
    }

    static func string(_ value: Any?) -> String? {
        value as? String
    }

    static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func array(_ value: Any?) -> [Any]? {
        value as? [Any]
    }
}

func remainingFraction(usedPercent: Double) -> Double {
    min(1, max(0, (100 - usedPercent) / 100))
}
