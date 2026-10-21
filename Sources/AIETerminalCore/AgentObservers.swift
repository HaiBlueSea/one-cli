import Foundation

/// Claude Code observer settings. The file contains hooks only, so `--settings`
/// adds observation without replacing permissions or approval policy.
public enum ClaudeObserverSettings: Sendable {
    public static let events = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PermissionRequest",
        "Notification",
        "Stop",
        "StopFailure",
        "SessionEnd"
    ]

    public static func json(helperPath: String) throws -> Data {
        let command = AgentObserverCommand.shell(helperPath: helperPath)
        var hooks: [String: Any] = [:]
        let observer: [String: Any] = ["type": "command", "command": command, "timeout": 3]
        for event in events {
            hooks[event] = [["hooks": [observer]]]
        }
        return try JSONSerialization.data(withJSONObject: ["hooks": hooks], options: [.prettyPrinted, .sortedKeys])
    }

    public static func apply(
        _ current: AgentActivity,
        hook: String,
        turnID: String?,
        payload: [String: JSONValue] = [:],
        now: Date = Date()
    ) -> AgentActivity {
        if hook == "PermissionRequest" || (hook == "Notification" && needsInput(payload)) {
            var next = current
            next.state = "needsInput"
            next.expiresAt = now.addingTimeInterval(CodexHookAdapter.validity)
            return next
        }
        if hook == "Notification" {
            return current
        }
        if hook == "Stop" {
            return AgentActivity(state: "idle")
        }
        if hook == "StopFailure" {
            return AgentActivity(state: "unknown")
        }
        return CodexHookAdapter.apply(current, hook: hook, turnID: turnID, payload: payload, now: now)
    }

    private static func needsInput(_ payload: [String: JSONValue]) -> Bool {
        let type = payload["notification_type"]?.stringValue ?? ""
        return [
            "permission_prompt",
            "agent_needs_input",
            "elicitation_dialog",
            "elicitation_url_dialog"
        ].contains(type)
    }
}

/// Cursor hook contract. Permission events are omitted because an empty
/// response blocks the action. This CLI build did not execute project or
/// plugin hooks during a completed headless turn, so the app does not write them.
public enum CursorObserverPlugin: Sendable {
    public static let events = [
        "sessionStart",
        "beforeSubmitPrompt",
        "postToolUse",
        "afterShellExecution",
        "afterFileEdit",
        "stop",
        "sessionEnd"
    ]

    public static func hooksObject(helperPath: String) -> [String: Any] {
        let command = AgentObserverCommand.shell(helperPath: helperPath)
        var hooks: [String: Any] = [:]
        for event in events {
            var entry: [String: Any] = ["command": command, "timeout": 3]
            if event == "stop" {
                entry["loop_limit"] = 0
            }
            hooks[event] = [entry]
        }
        return ["version": 1, "hooks": hooks]
    }

    public static func apply(
        _ current: AgentActivity,
        hook: String,
        turnID: String?,
        payload: [String: JSONValue] = [:],
        now: Date = Date()
    ) -> AgentActivity {
        if hook == "subagentStart" || hook == "subagentStop" {
            return current
        }
        switch hook {
        case "sessionStart":
            return CodexHookAdapter.apply(current, hook: "SessionStart", turnID: nil, payload: payload, now: now)
        case "beforeSubmitPrompt":
            return CodexHookAdapter.apply(current, hook: "UserPromptSubmit", turnID: turnID, payload: payload, now: now)
        case "postToolUse", "afterShellExecution", "afterFileEdit", "afterAgentResponse":
            return CodexHookAdapter.apply(current, hook: "PreToolUse", turnID: turnID, payload: payload, now: now)
        case "stop":
            switch payload["status"]?.stringValue {
            case "error":
                return CodexHookAdapter.apply(current, hook: "StopFailure", turnID: turnID, payload: payload, now: now)
            case "aborted":
                return CodexHookAdapter.apply(current, hook: "Interrupt", turnID: turnID, payload: payload, now: now)
            default:
                return CodexHookAdapter.apply(current, hook: "Stop", turnID: turnID, payload: payload, now: now)
            }
        case "sessionEnd":
            return CodexHookAdapter.apply(current, hook: "SessionEnd", turnID: turnID, payload: payload, now: now)
        default:
            return current
        }
    }
}

public enum AgentObserverCommand: Sendable {
    public static func shell(helperPath: String) -> String {
        let escaped = helperPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\" --agent"
    }
}

public enum AgentObserverInstall {
    public static func installClaudeSettings(flavor: AppFlavor, helperPath: String) throws -> String {
        let root = try RuntimePaths.supportDirectory(flavor: flavor)
            .appendingPathComponent("agent-observers", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let settings = root.appendingPathComponent("claude-settings.json")
        try ClaudeObserverSettings.json(helperPath: helperPath).write(to: settings, options: .atomic)
        return settings.path
    }
}

public enum NativeCLIHooks {
    public static func installInstalledHomes(helperPath: String) {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        try? installKimi(home: home.appendingPathComponent(".kimi-code", isDirectory: true), helperPath: helperPath)
        try? installClaude(home: home.appendingPathComponent(".claude", isDirectory: true), helperPath: helperPath)
    }

    public static func installCodex(home: URL, helperPath: String) throws {
        guard directoryExists(home) else { return }
        let url = home.appendingPathComponent("hooks.json")
        guard staysInside(url, home: home) else { return }
        let existing = try readExisting(url)
        let merged = try CodexObserverHooks.mergeJSON(existing, helperPath: helperPath)
        try writeIfChanged(merged, to: url, permissions: 0o600)
    }

    public static func installKimi(home: URL, helperPath: String) throws {
        guard directoryExists(home) else { return }
        let url = home.appendingPathComponent("config.toml")
        guard staysInside(url, home: home) else { return }
        let data = try readExisting(url)
        let existing: String
        if let data {
            guard let text = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            existing = text
        } else { existing = "" }
        let merged = KimiObserverHome.mergeConfig(existing, helperPath: helperPath)
        guard merged != existing else { return }
        try Data(merged.utf8).write(to: url, options: .atomic)
    }

    public static func installClaude(home: URL, helperPath: String) throws {
        guard directoryExists(home) else { return }
        let url = home.appendingPathComponent("settings.json")
        guard staysInside(url, home: home) else { return }
        let existing = try readExisting(url)
        let merged = try mergeClaudeSettings(existing, helperPath: helperPath)
        try writeIfChanged(merged, to: url, permissions: 0o600)
    }

    static func mergeClaudeSettings(_ existing: Data?, helperPath: String) throws -> Data {
        var root: [String: Any] = [:]
        if let existing, !existing.isEmpty,
           let parsed = try JSONSerialization.jsonObject(with: existing) as? [String: Any] {
            root = parsed
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let command = AgentObserverCommand.shell(helperPath: helperPath)
        let observer: [String: Any] = ["type": "command", "command": command, "timeout": 3]
        for event in ClaudeObserverSettings.events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            var found = false
            for index in groups.indices {
                guard var inner = groups[index]["hooks"] as? [[String: Any]] else { continue }
                for hookIndex in inner.indices {
                    guard let text = inner[hookIndex]["command"] as? String, text.contains(CodexObserverHooks.marker) else { continue }
                    inner[hookIndex]["type"] = "command"
                    inner[hookIndex]["command"] = command
                    groups[index]["hooks"] = inner
                    found = true
                }
            }
            if !found { groups.append(["hooks": [observer]]) }
            hooks[event] = groups
        }
        root["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    private static func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func staysInside(_ url: URL, home: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return true }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let root = home.resolvingSymlinksInPath().standardizedFileURL
        return resolved.path == root.path || resolved.path.hasPrefix(root.path + "/")
    }

    private static func writeIfChanged(_ data: Data, to url: URL, permissions: Int) throws {
        if try readExisting(url) == data { return }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    private static func readExisting(_ url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch CocoaError.fileReadNoSuchFile { return nil }
    }
}
