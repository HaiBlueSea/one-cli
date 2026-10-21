import Foundation

/// Kimi Code hooks live in `config.toml`. The overlay keeps the user's home by
/// symlink and writes hooks only into the copy, so approval settings stay put.
public enum KimiObserverHome: Sendable {
    public static let marker = "AIEHookHelper"
    public static let events = [
        "SessionStart",
        "TurnStarted",
        "UserPromptSubmit",
        "PermissionRequest",
        "PermissionResult",
        "Stop",
        "Interrupt",
        "StopFailure",
        "TaskStarted",
        "Notification",
        "SessionEnd"
    ]

    public static func mergeConfig(_ existing: String, helperPath: String) -> String {
        var kept: [String] = []
        var section: [String] = []
        var inHooks = false
        func flush() {
            let body = section.joined(separator: "\n")
            if !(inHooks && body.contains(marker)) {
                kept.append(contentsOf: section)
            }
            section = []
            inHooks = false
        }
        for line in existing.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[[") {
                flush()
                inHooks = trimmed == "[[hooks]]"
            } else if trimmed.hasPrefix("[") && !trimmed.hasPrefix("[[") {
                flush()
            }
            section.append(line)
        }
        flush()
        var text = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let command = toml(AgentObserverCommand.shell(helperPath: helperPath))
        let blocks = events.map { event in
            "[[hooks]]\nevent = \"\(event)\"\ncommand = \"\(command)\"\ntimeout = 3"
        }.joined(separator: "\n\n")
        if !text.isEmpty { text += "\n\n" }
        return text + blocks + "\n"
    }

    public static func prepare(source: URL, overlay: URL, helperPath: String) throws {
        let source = source.standardizedFileURL
        let overlay = overlay.standardizedFileURL
        guard source.path != overlay.path else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: overlay, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let names = (try? fm.contentsOfDirectory(atPath: source.path)) ?? []
        for name in names where name != "config.toml" && !name.hasPrefix(".") {
            let target = source.appendingPathComponent(name)
            let dest = overlay.appendingPathComponent(name)
            if let current = try? fm.destinationOfSymbolicLink(atPath: dest.path),
               URL(fileURLWithPath: current).standardizedFileURL.path == target.path {
                continue
            }
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.createSymbolicLink(at: dest, withDestinationURL: target)
        }
        let existing = (try? String(contentsOf: source.appendingPathComponent("config.toml"), encoding: .utf8)) ?? ""
        let merged = mergeConfig(existing, helperPath: helperPath)
        let config = overlay.appendingPathComponent("config.toml")
        try Data(merged.utf8).write(to: config, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
    }

    private static func toml(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

public enum KimiHookAdapter: Sendable {
    public static func apply(
        _ current: AgentActivity,
        hook: String,
        turnID: String?,
        payload: [String: JSONValue] = [:],
        now: Date = Date()
    ) -> AgentActivity {
        if hook == "SubagentStart" || hook == "SubagentStop" || hook == "UserPromptQueued" {
            return current
        }
        if hook == "TurnStarted" && payload["origin_kind"]?.stringValue == "subagent" {
            return current
        }
        switch hook {
        case "SessionStart":
            return CodexHookAdapter.apply(current, hook: "SessionStart", turnID: nil, payload: payload, now: now)
        case "TurnStarted":
            return beginTurn(current, turnID: turnID, now: now)
        case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionResult":
            return beginTurn(current, turnID: hook == "UserPromptSubmit" ? turnID : nil, now: now)
        case "PermissionRequest":
            var next = current
            next.state = "needsInput"
            next.expiresAt = now.addingTimeInterval(CodexHookAdapter.validity)
            return next
        case "TaskStarted":
            var next = current
            let id = "task:" + (payload["task_id"]?.stringValue ?? turnID ?? "task")
            next.activeTurnIDs.insert(id)
            next.state = "working"
            next.expiresAt = now.addingTimeInterval(CodexHookAdapter.validity)
            return next
        case "Notification":
            return finishTask(current, payload: payload, now: now)
        case "Stop", "Interrupt":
            return finishTurn(current, now: now)
        case "StopFailure":
            var next = finishTurn(current, now: now)
            if next.activeTurnIDs.isEmpty { next.state = "unknown" }
            return next
        case "SessionEnd":
            return CodexHookAdapter.apply(current, hook: "SessionEnd", turnID: nil, payload: payload, now: now)
        default:
            return current
        }
    }

    private static func beginTurn(_ current: AgentActivity, turnID: String?, now: Date) -> AgentActivity {
        var next = current
        if let turnID { next.activeTurnIDs.insert(turnID) }
        next.state = "working"
        next.expiresAt = now.addingTimeInterval(CodexHookAdapter.validity)
        return next
    }

    private static func finishTurn(_ current: AgentActivity, now: Date) -> AgentActivity {
        var next = current
        next.activeTurnIDs = next.activeTurnIDs.filter { $0.hasPrefix("task:") }
        if next.activeTurnIDs.isEmpty {
            next.state = "idle"
            next.expiresAt = nil
        } else {
            next.state = "working"
            next.expiresAt = now.addingTimeInterval(CodexHookAdapter.validity)
        }
        return next
    }

    private static func finishTask(_ current: AgentActivity, payload: [String: JSONValue], now: Date) -> AgentActivity {
        let type = payload["notification_type"]?.stringValue ?? ""
        guard type.contains("completed") || type.contains("failed") || type.contains("stopped") else {
            return current
        }
        var next = current
        if let taskID = payload["task_id"]?.stringValue {
            next.activeTurnIDs.remove("task:" + taskID)
        } else if next.activeTurnIDs.filter({ $0.hasPrefix("task:") }).count <= 1 {
            next.activeTurnIDs = next.activeTurnIDs.filter { !$0.hasPrefix("task:") }
        }
        let tasks = next.activeTurnIDs.contains { $0.hasPrefix("task:") }
        let turns = next.activeTurnIDs.contains { !$0.hasPrefix("task:") }
        if !tasks && !turns {
            next.state = "idle"
            next.expiresAt = nil
        }
        return next
    }
}
