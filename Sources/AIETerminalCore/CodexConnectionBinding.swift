import Foundation

/// Projects only routing metadata while streaming JSON. Transcript, prompt and
/// image strings are skipped, including in arbitrarily large resume responses.
public struct CodexWireMetadata {
    public private(set) var values: [String: JSONValue] = [:]
    private struct Container {
        var object: Bool
        var path: String?
        var key: String?
        var wantsKey = true
    }
    private static let leaves: Set<String> = [
        "id", "method", "error", "params.threadId", "params.ephemeral", "params.threadSource",
        "result.thread.id", "result.thread.source", "result.thread.status.type",
        "result.thread.status.activeFlags.*", "params.status.type", "params.status.activeFlags.*"
    ]
    private static let prefixes: Set<String> = {
        var result: Set<String> = [""]
        for leaf in leaves {
            let parts = leaf.split(separator: ".")
            for count in 1...parts.count { result.insert(parts.prefix(count).joined(separator: ".")) }
        }
        return result
    }()
    private var stack: [Container] = []
    private var string = false
    private var escaped = false
    private var keyToken = false
    private var tokenPath: String?
    private var token = Data()
    private var literal = false
    private var valid = true
    private var finished = false

    public init() {}

    public var complete: Bool { valid && finished && !string && !literal && stack.isEmpty }

    private var valuePath: String? {
        guard let parent = stack.last else { return "" }
        guard let path = parent.path else { return nil }
        if !parent.object { return path + ".*" }
        guard let key = parent.key else { return nil }
        return path.isEmpty ? key : path + "." + key
    }

    public mutating func consume(_ byte: UInt8) {
        guard valid else { return }
        if string {
            if keyToken || tokenPath != nil {
                guard token.count < 2048 else { valid = false; return }
                token.append(byte)
            }
            if escaped { escaped = false; return }
            if byte == 92 { escaped = true; return }
            if byte == 34 { string = false; finishToken() }
            return
        }
        if literal {
            if byte == 44 || byte == 125 || byte == 93 || byte <= 32 {
                literal = false
                finishToken()
            } else {
                if tokenPath != nil {
                    guard token.count < 100 else { valid = false; return }
                    token.append(byte)
                }
                return
            }
        }
        if byte <= 32 { return }
        guard !finished else { valid = false; return }
        switch byte {
        case 34:
            string = true
            keyToken = stack.last.map { $0.object && $0.wantsKey && $0.path != nil } ?? false
            tokenPath = valuePath.flatMap { Self.leaves.contains($0) ? $0 : nil }
            token = keyToken || tokenPath != nil ? Data([34]) : Data()
        case 123, 91:
            guard stack.count < 128 else { valid = false; return }
            let path = valuePath.flatMap { Self.prefixes.contains($0) ? $0 : nil }
            if path == "error" || path == "result.thread.source" { values[path!] = .bool(true) }
            stack.append(Container(object: byte == 123, path: path))
        case 125, 93:
            guard let parent = stack.popLast(), parent.object == (byte == 125) else { valid = false; return }
            if stack.isEmpty { finished = true }
        case 44:
            if !stack.isEmpty { stack[stack.count - 1].key = nil; stack[stack.count - 1].wantsKey = true }
        case 58: break
        default:
            literal = true
            keyToken = false
            tokenPath = valuePath.flatMap { Self.leaves.contains($0) ? $0 : nil }
            token = tokenPath == nil ? Data() : Data([byte])
        }
    }

    private mutating func finishToken() {
        defer { token.removeAll(keepingCapacity: true); tokenPath = nil }
        guard keyToken || tokenPath != nil else { return }
        guard let array = try? JSONSerialization.jsonObject(with: Data([91]) + token + Data([93])) as? [Any],
              let item = array.first else { valid = false; return }
        if keyToken {
            guard !stack.isEmpty, let key = item as? String else { valid = false; return }
            stack[stack.count - 1].key = key
            stack[stack.count - 1].wantsKey = false
        } else if let path = tokenPath {
            if path.hasSuffix(".*") {
                if let flag = item as? String, ["waitingOnApproval", "waitingOnUserInput"].contains(flag) {
                    values[path + "." + flag] = .bool(true)
                }
            } else if let value = try? JSONDecoder().decode(JSONValue.self, from: token) {
                values[path] = value
            }
        }
    }

    public func state(at prefix: String) -> String {
        switch values[prefix + ".type"]?.stringValue {
        case "idle": return "idle"
        case "active":
            return values[prefix + ".activeFlags.*.waitingOnApproval"] != nil
                || values[prefix + ".activeFlags.*.waitingOnUserInput"] != nil ? "needsInput" : "working"
        default: return "unknown"
        }
    }
}

/// Passive WebSocket decoder. Forwarding never depends on successful decoding.
/// Memory is bounded by frame headers and the metadata projector, not payload size.
public struct CodexWireObserver {
    private var handshake = Data()
    private var upgraded: Bool
    private var disabled = false
    private let masked: Bool
    private var header = [UInt8]()
    private var remaining: UInt64 = 0
    private var mask = [UInt8]()
    private var offset = 0
    private var opcode: UInt8 = 0
    private var final = false
    private var textMessage = false
    private var metadata = CodexWireMetadata()

    public init(masked: Bool, upgraded: Bool = false) {
        self.masked = masked
        self.upgraded = upgraded
    }

    public mutating func consume(_ data: Data, onMessage: (CodexWireMetadata) -> Void) {
        for byte in data {
            guard !disabled else { return }
            if !upgraded {
                guard handshake.count < 8192 else { disabled = true; return }
                handshake.append(byte)
                if handshake.suffix(4).elementsEqual([13, 10, 13, 10]) {
                    upgraded = true
                    handshake.removeAll()
                }
                continue
            }
            if remaining > 0 {
                let decoded = mask.isEmpty ? byte : byte ^ mask[offset % 4]
                if opcode == 1 || opcode == 0, textMessage { metadata.consume(decoded) }
                offset = (offset + 1) % 4
                remaining -= 1
                if remaining == 0 { finishFrame(onMessage) }
                continue
            }
            header.append(byte)
            guard header.count >= 2 else { continue }
            let lengthKind = header[1] & 127
            let lengthBytes = lengthKind == 127 ? 8 : lengthKind == 126 ? 2 : 0
            let headerLength = 2 + lengthBytes + (masked ? 4 : 0)
            guard header.count == headerLength else { continue }
            guard (header[1] & 128 != 0) == masked, header[0] & 112 == 0 else { disabled = true; return }
            opcode = header[0] & 15
            final = header[0] & 128 != 0
            remaining = lengthBytes == 0 ? UInt64(lengthKind) : header[2..<(2 + lengthBytes)].reduce(0) { ($0 << 8) | UInt64($1) }
            mask = masked ? Array(header.suffix(4)) : []
            offset = 0
            if opcode == 1 { textMessage = true; metadata = CodexWireMetadata() }
            else if opcode == 2 { textMessage = false }
            header.removeAll(keepingCapacity: true)
            if remaining == 0 { finishFrame(onMessage) }
        }
    }

    private mutating func finishFrame(_ onMessage: (CodexWireMetadata) -> Void) {
        if final, opcode == 0 || opcode == 1 || opcode == 2 {
            if textMessage, metadata.complete { onMessage(metadata) }
            textMessage = false
        }
    }
}

/// One binding per launched TUI, established only by its own successful main
/// start/resume/fork RPC. Global notifications and temporary threads cannot bind.
public final class CodexConnectionBinding: @unchecked Sendable {
    private let lock = NSLock()
    private let onState: @Sendable (String?, String) -> Void
    private var pending: (connection: Int, id: JSONValue, wanted: String?)?
    private var selected: (connection: Int, id: String)?
    private var lastID: String?
    private var lastState: String?

    public init(onState: @escaping @Sendable (String?, String) -> Void) { self.onState = onState }

    public func client(_ message: CodexWireMetadata, connection: Int) {
        lock.withLock {
            let values = message.values
            let method = values["method"]?.stringValue ?? ""
            if ["thread/start", "thread/resume", "thread/fork"].contains(method), let id = values["id"] {
                if values["params.ephemeral"] == .bool(true) { return }
                if let source = values["params.threadSource"]?.stringValue, source != "user" { return }
                pending = (connection, id, method == "thread/resume" ? values["params.threadId"]?.stringValue : nil)
                selected = nil
                publish(nil, "unknown")
            }
            if method == "thread/unsubscribe", let selected, selected.connection == connection,
               values["params.threadId"]?.stringValue == selected.id {
                self.selected = nil
                publish(nil, "unknown")
            }
        }
    }

    public func server(_ message: CodexWireMetadata, connection: Int) {
        lock.withLock {
            let values = message.values
            if let pending, pending.connection == connection, values["id"] == pending.id {
                self.pending = nil
                guard values["error"] == nil, let id = values["result.thread.id"]?.stringValue,
                      !id.isEmpty, id.utf8.count <= 200,
                      pending.wanted == nil || pending.wanted == id,
                      values["result.thread.source"] != .bool(true) else { publish(nil, "unknown"); return }
                selected = (connection, id)
                publish(id, message.state(at: "result.thread.status"))
                return
            }
            guard let selected, selected.connection == connection,
                  values["params.threadId"]?.stringValue == selected.id else { return }
            switch values["method"]?.stringValue {
            case "thread/status/changed": publish(selected.id, message.state(at: "params.status"))
            case "thread/closed": self.selected = nil; publish(nil, "unknown")
            default: break
            }
        }
    }

    public func disconnected(_ connection: Int) {
        lock.withLock {
            if pending?.connection == connection { pending = nil }
            if selected?.connection == connection { selected = nil; publish(nil, "unknown") }
        }
    }

    private func publish(_ id: String?, _ state: String) {
        guard lastID != id || lastState != state else { return }
        lastID = id; lastState = state
        onState(id, state)
    }
}
