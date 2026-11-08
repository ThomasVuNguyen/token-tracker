import Foundation

public enum FixtureCheck {
    public static func assertParsers() throws {
        let claude = try ClaudeProvider.parse(Data(claudeJSON.utf8), plan: "Team · 5x")
        try expect(claude.plan == "Team · 5x", "claude plan")
        try expect(claude.meters.map(\.label) == ["Session", "Weekly", "Fable"], "claude labels")
        try expect(claude.meters.map(\.remainingPercent) == [74, 51, 68], "claude percents")
        try expect(
            ClaudeProvider.planLabel(subscription: "team", tier: "default_claude_max_5x") == "Team · 5x",
            "plan label"
        )

        let codex = try CodexProvider.parse(Data(codexJSON.utf8))
        try expect(codex.plan == "Plus", "codex plan")
        try expect(codex.meters.map(\.label) == ["Session", "Weekly", "Credits"], "codex labels")
        try expect(codex.meters[0].remainingPercent == 57, "codex session")
        try expect(codex.meters[1].remainingPercent == 71, "codex weekly")
        try expect(codex.meters[2].detail == "410 left", "codex credits")

        let cursor = try CursorProvider.parse(Data(cursorJSON.utf8))
        try expect(cursor.meters.map(\.label) == ["Auto", "API"], "cursor labels")
        try expect(cursor.meters.map(\.remainingPercent) == [86, 100], "cursor percents")
        try expect(
            cursor.note == "Included $20 of $20",
            "cursor note"
        )

        let antigravity = try AntigravityProvider.parse(Data(antigravityJSON.utf8), plan: "Ultra")
        try expect(antigravity.meters.map(\.label) == ["Gemini", "Claude / GPT"], "antigravity labels")
        try expect(antigravity.meters.map(\.remainingPercent) == [47, 89], "antigravity percents")
    }

    private static func expect(_ condition: Bool, _ label: String) throws {
        if !condition { throw CheckError(label) }
    }
}

private struct CheckError: Error, CustomStringConvertible {
    var label: String
    var description: String { "fixture check failed: \(label)" }
    init(_ label: String) { self.label = label }
}

private let claudeJSON = """
{
  "limits": [
    {"kind": "session", "percent": 26, "resets_at": "2026-11-08T04:10:00Z"},
    {"kind": "weekly_all", "percent": 49, "resets_at": "2026-11-10T20:00:00Z"},
    {"kind": "weekly_scoped", "percent": 32, "resets_at": "2026-11-10T20:00:00Z",
     "scope": {"model": {"display_name": "Fable"}}}
  ]
}
"""

private let codexJSON = """
{
  "plan_type": "plus",
  "rate_limit": {
    "primary_window": {"used_percent": 43, "limit_window_seconds": 18000, "reset_at": 1794111639},
    "secondary_window": {"used_percent": 29, "limit_window_seconds": 604800, "reset_at": 1794430161}
  },
  "credits": {"has_credits": true, "balance": "410.046"}
}
"""

private let cursorJSON = """
{
  "billingCycleEnd": "1795996068000",
  "planUsage": {
    "includedSpend": 2000,
    "limit": 2000,
    "autoPercentUsed": 14.16,
    "apiPercentUsed": 0
  },
  "displayMessage": "You've hit your usage limit"
}
"""

private let antigravityJSON = """
{
  "groups": [
    {
      "buckets": [
        {"displayName": "Gemini 3.8 Flash (High)", "remainingFraction": 0.47, "resetTime": "2026-11-08T04:28:41Z"},
        {"displayName": "Gemini 3.8 Flash (Low)", "remainingFraction": 0.52, "resetTime": "2026-11-08T04:28:41Z"},
        {"displayName": "Claude Sonnet 4.6 (Thinking)", "remainingFraction": 0.89, "resetTime": "2026-11-08T04:28:40Z"},
        {"displayName": "GPT-OSS 120B (Medium)", "remainingFraction": 0.91, "resetTime": "2026-11-08T04:28:40Z"}
      ]
    }
  ]
}
"""
