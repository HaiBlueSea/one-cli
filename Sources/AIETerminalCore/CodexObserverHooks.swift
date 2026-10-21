import Foundation

public enum CodexObserverHooks: Sendable {
    public static let marker = "AIEHookHelper"
    public static let events = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "Notification",
        "Stop",
        "Interrupt",
        "StopFailure",
        "SessionEnd"
    ]

    public static func command(helperPath: String) -> String {
        "\"\(helperPath)\" --agent"
    }

    public static func mergeJSON(_ existing: Data?, helperPath: String) throws -> Data {
        var root: [String: Any] = [:]
        if let existing, !existing.isEmpty,
           let parsed = try JSONSerialization.jsonObject(with: existing) as? [String: Any] {
            root = parsed
        }
        if root["description"] == nil {
            root["description"] = "AI Terminal observer. Observe only; do not change approval."
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let helperCommand = command(helperPath: helperPath)
        let observer: [String: Any] = [
            "type": "command",
            "command": helperCommand,
            "timeout": 3
        ]
        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            var found = false
            for index in groups.indices {
                guard var inner = groups[index]["hooks"] as? [[String: Any]] else { continue }
                for hookIndex in inner.indices {
                    guard let text = inner[hookIndex]["command"] as? String, text.contains(marker) else {
                        continue
                    }
                    inner[hookIndex]["type"] = "command"
                    inner[hookIndex]["command"] = helperCommand
                    groups[index]["hooks"] = inner
                    found = true
                }
            }
            if !found {
                groups.append(["hooks": [observer]])
            }
            hooks[event] = groups
        }
        root["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    public static func install(in directory: String, helperPath: String, home: String) throws {
        let cwd = URL(fileURLWithPath: directory).standardizedFileURL
        let homeURL = URL(fileURLWithPath: home).standardizedFileURL
        guard cwd.path != homeURL.path else { return }
        guard cwd.path != homeURL.appendingPathComponent(".codex").path else { return }
        let destDir = cwd.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let dest = destDir.appendingPathComponent("hooks.json")
        let existing = try? Data(contentsOf: dest)
        let merged = try mergeJSON(existing, helperPath: helperPath)
        if existing != merged {
            try merged.write(to: dest, options: .atomic)
        }
    }
}
