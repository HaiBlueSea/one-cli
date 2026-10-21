import Foundation

public enum HookPayloadFilter: Sendable {
    private static let allowedKeys: Set<String> = [
        "hook_event_name",
        "hookEventName",
        "event",
        "session_id",
        "session_pid",
        "conversation_id",
        "generation_id",
        "turn_id",
        "prompt_id",
        "task_id",
        "cwd",
        "tool_name",
        "origin_kind",
        "origin_name",
        "notification_type",
        "reason",
        "is_interrupt",
        "agent_id",
        "agent_type",
        "model",
        "permission_mode",
        "detached",
        "queue_length",
        "uptime_ms",
        "source",
        "client_type",
        "matcher",
        "status",
        "decision",
        "blocked",
        "success"
    ]

    private static let deniedKeys: Set<String> = [
        "prompt",
        "tool_input",
        "tool_response",
        "transcript_path",
        "additionalContext",
        "additional_context",
        "command",
        "content",
        "diff",
        "systemMessage",
        "text",
        "input",
        "output"
    ]

    public static func extract(from jsonObject: Any) -> [String: JSONValue] {
        guard let object = jsonObject as? [String: Any] else {
            return [:]
        }
        var payload: [String: JSONValue] = [:]
        for (key, value) in object {
            if deniedKeys.contains(key) {
                continue
            }
            if allowedKeys.contains(key) {
                payload[key] = scalar(from: value)
            }
        }
        if let nested = object["hookSpecificOutput"] as? [String: Any] {
            if let name = nested["hookEventName"] as? String {
                payload["hookEventName"] = .string(name)
            }
        }
        if payload["session_id"] == nil, let conversation = payload["conversation_id"] {
            payload["session_id"] = conversation
        }
        return payload
    }

    public static func extract(fromJSONData data: Data) -> [String: JSONValue] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return ["parse_error": .bool(true)]
        }
        return extract(from: object)
    }

    private static func scalar(from value: Any) -> JSONValue {
        switch value {
        case let value as String:
            return .string(String(value.prefix(200)))
        case let value as Bool:
            return .bool(value)
        case let value as Int:
            return .int(value)
        case let value as Double:
            guard let integer = Int(exactly: value.rounded(.towardZero)) else { return .null }
            return .int(integer)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            return .int(value.intValue)
        default:
            return .string(String(describing: value).prefix(80).description)
        }
    }
}
