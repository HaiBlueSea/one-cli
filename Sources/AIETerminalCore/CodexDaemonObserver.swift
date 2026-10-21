import Foundation

/// Only initialize/list/read requests; never resumes a thread or handles approvals.
public final class CodexDaemonObserver: @unchecked Sendable {
    private let socket: LocalWebSocket
    private let onState: @Sendable (String) -> Void
    private let lock = NSLock()
    private var stopped = false
    private var started = false
    private var lastState: String?
    private var states: [String: String] = [:]
    private var ignored = Set<String>()
    private var pending: [Int: String] = [:]
    private var nextID = 3
    private var failure: String?
    public var failureReason: String? { lock.withLock { failure } }

    public init(socketURL: URL, onState: @escaping @Sendable (String) -> Void) {
        socket = LocalWebSocket(destination: socketURL)
        self.onState = onState
    }

    public func start() {
        guard lock.withLock({
            guard !started, !stopped else { return false }
            started = true
            return true
        }) else { return }
        let thread = Thread { [self] in
            defer { socket.finish() }
            var phase = "connect"
            do {
                try socket.connect()
                phase = "protocol"
                try socket.sendJSON(["method": "initialize", "id": 1, "params": ["clientInfo": ["name": "ai_terminal_observer", "version": "0.1"], "capabilities": ["experimentalApi": true]]])
                while !lock.withLock({ stopped }) { try consume(socket.receiveJSON()) }
            } catch {
                lock.withLock { if failure == nil { failure = phase + ": " + String(describing: error) } }
                publish("unknown")
            }
        }
        thread.name = "aie-codex-state"
        thread.start()
    }

    public func stop() {
        lock.withLock { stopped = true }
        socket.cancel()
    }

    private func publish(_ state: String) {
        guard !lock.withLock({ stopped }), state != lastState else { return }
        lastState = state
        onState(state)
    }

    private func requestThread(_ id: String) throws {
        guard !id.isEmpty, id.count <= 200, !ignored.contains(id), !pending.values.contains(id) else { return }
        guard states.count + ignored.count + pending.count < 256 else { throw LocalWebSocket.Failure.oversized }
        let request = nextID
        nextID += 1
        pending[request] = id
        try socket.sendJSON(["method": "thread/read", "id": request, "params": ["threadId": id, "includeTurns": false]])
    }

    private func record(_ thread: [String: Any]) throws {
        guard let id = thread["id"] as? String, !id.isEmpty, id.count <= 200 else { throw LocalWebSocket.Failure.invalidProtocol }
        guard states[id] != nil || ignored.contains(id) || states.count + ignored.count < 256 else { throw LocalWebSocket.Failure.oversized }
        if (thread["parentThreadId"] as? String) != nil || (thread["source"] as? [String: Any])?["subagent"] != nil {
            ignored.insert(id); states[id] = nil
        } else {
            guard states[id] != nil || states.count + ignored.count < 256 else { throw LocalWebSocket.Failure.oversized }
            states[id] = Self.state(thread["status"] as? [String: Any] ?? [:])
        }
    }

    public static func state(_ status: [String: Any]) -> String {
        switch status["type"] as? String {
        case "idle": return "idle"
        case "active":
            let flags = status["activeFlags"] as? [String] ?? []
            return flags.contains("waitingOnApproval") || flags.contains("waitingOnUserInput") ? "needsInput" : "working"
        default: return "unknown"
        }
    }

    private func consume(_ message: [String: Any]) throws {
        if let method = message["method"] as? String {
            let params = message["params"] as? [String: Any] ?? [:]
            if method == "thread/started", let thread = params["thread"] as? [String: Any] { try record(thread) }
            if method == "thread/status/changed", let id = params["threadId"] as? String, !ignored.contains(id) {
                if states[id] != nil { states[id] = Self.state(params["status"] as? [String: Any] ?? [:]) }
                else { try requestThread(id) }
            }
            if method == "thread/closed", let id = params["threadId"] as? String { states[id] = nil; ignored.remove(id) }
        } else if let id = message["id"] as? Int {
            if let error = message["error"] as? [String: Any] {
                lock.withLock { failure = "rpc \(id): " + String(describing: error["message"] ?? error["code"] ?? "rejected").prefix(200) }
                throw LocalWebSocket.Failure.invalidProtocol
            }
            if id == 1 {
                try socket.sendJSON(["method": "initialized", "params": [:]])
                try socket.sendJSON(["method": "thread/loaded/list", "id": 2, "params": [:]])
            } else if id == 2 {
                guard let result = message["result"] as? [String: Any], let ids = result["data"] as? [String], ids.count <= 256 else { throw LocalWebSocket.Failure.oversized }
                for id in ids { try requestThread(id) }
            } else if pending.removeValue(forKey: id) != nil, let result = message["result"] as? [String: Any], let thread = result["thread"] as? [String: Any] {
                try record(thread)
            }
        }
        if states.values.contains("needsInput") { publish("needsInput") }
        else if states.values.contains("working") { publish("working") }
        else if !states.isEmpty, pending.isEmpty, states.values.allSatisfy({ $0 == "idle" }) { publish("idle") }
        else { publish("unknown") }
    }
}
