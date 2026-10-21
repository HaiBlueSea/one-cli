import Foundation

public struct AgentActivity: Sendable, Equatable {
    public var state: String
    public var activeTurnIDs: Set<String>
    public var expiresAt: Date?

    public static let none = AgentActivity(state: "none", activeTurnIDs: [], expiresAt: nil)

    public init(state: String, activeTurnIDs: Set<String> = [], expiresAt: Date? = nil) {
        self.state = state
        self.activeTurnIDs = activeTurnIDs
        self.expiresAt = expiresAt
    }
}

public enum CodexHookAdapter: Sendable {
    public static let validity: TimeInterval = 120

    public static func hookName(from payload: [String: JSONValue]) -> String? {
        payload["hook_event_name"]?.stringValue
            ?? payload["hookEventName"]?.stringValue
            ?? payload["event"]?.stringValue
    }

    public static func isSubagent(hook: String, payload: [String: JSONValue]) -> Bool {
        if hook == "SubagentStart" || hook == "SubagentStop" {
            return true
        }
        if payload["agent_type"]?.stringValue == "subagent" {
            return true
        }
        if payload["origin_kind"]?.stringValue == "subagent" {
            return true
        }
        return false
    }

    public static func apply(
        _ current: AgentActivity,
        hook: String,
        turnID: String?,
        payload: [String: JSONValue] = [:],
        now: Date = Date()
    ) -> AgentActivity {
        if isSubagent(hook: hook, payload: payload) {
            return current
        }
        var next = current
        switch hook {
        case "SessionStart":
            if current.state == "none" || current.state == "unknown" {
                next.state = "idle"
                next.activeTurnIDs = []
                next.expiresAt = nil
            }
        case "UserPromptSubmit":
            let id = turnID ?? "current"
            if next.activeTurnIDs.count >= 256, !next.activeTurnIDs.contains(id) {
                return AgentActivity(state: "unknown")
            }
            next.state = "working"
            next.activeTurnIDs.insert(id)
            next.expiresAt = now.addingTimeInterval(validity)
        case "PreToolUse":
            next.state = "working"
            next.expiresAt = now.addingTimeInterval(validity)
        case "Notification":
            if isPermission(payload) {
                next.state = "needsInput"
                next.expiresAt = now.addingTimeInterval(validity)
            }
        case "Stop":
            if let turnID {
                next.activeTurnIDs.remove(turnID)
            } else if next.activeTurnIDs.count <= 1 {
                next.activeTurnIDs.removeAll()
            } else {
                next.state = "unknown"
                next.expiresAt = nil
                return next
            }
            if next.activeTurnIDs.isEmpty {
                next.state = "idle"
                next.expiresAt = nil
            } else {
                next.state = "working"
                next.expiresAt = now.addingTimeInterval(validity)
            }
        case "Interrupt":
            next.activeTurnIDs.removeAll()
            next.state = "idle"
            next.expiresAt = nil
        case "StopFailure":
            next.state = "unknown"
            next.expiresAt = nil
        case "SessionEnd":
            if current.state == "working" || current.state == "needsInput" {
                next.state = "unknown"
                next.expiresAt = nil
            }
        default:
            break
        }
        return next
    }

    public static func expire(_ current: AgentActivity, now: Date = Date()) -> AgentActivity {
        guard let expiresAt = current.expiresAt, now >= expiresAt else {
            return current
        }
        guard current.state == "working" || current.state == "needsInput" else {
            return current
        }
        return AgentActivity(state: "unknown", activeTurnIDs: current.activeTurnIDs, expiresAt: nil)
    }

    private static func isPermission(_ payload: [String: JSONValue]) -> Bool {
        let text = (payload["notification_type"]?.stringValue ?? payload["reason"]?.stringValue ?? "").lowercased()
        return text.contains("permission") || text.contains("approval") || text.contains("ask")
    }
}
