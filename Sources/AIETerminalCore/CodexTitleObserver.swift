import Foundation

/// The title supplies identity only. All activity comes from the native daemon.
public final class CodexTitleObserver: @unchecked Sendable {
    private let socket: LocalWebSocket
    private let prefix: String
    private let onState: @Sendable (String?, String) -> Void
    private let lock = NSLock()
    private var stopped = false
    private var started = false
    private var failure: String?
    private var loaded = Set<String>()
    private var added = Set<String>()
    private var removed = Set<String>()
    private var cursors = Set<String>()
    private var listing = true
    private var nextID = 2
    private var listRequest: Int?
    private var reads: [Int: String] = [:]
    private var threadID: String?
    private var lastState: String?
    private var lastThreadID: String?
    public var failureReason: String? { lock.withLock { failure } }

    public init(socketURL: URL, prefix: String, onState: @escaping @Sendable (String?, String) -> Void) {
        socket = LocalWebSocket(destination: socketURL)
        self.prefix = prefix
        self.onState = onState
    }

    /// Accept only an entire UUID or the CLI's explicit truncated UUID title.
    /// Other title fields and prompt text must never become identity hints.
    public static func sessionPrefix(title: String) -> String? {
        guard title.utf8.count <= 256 else { return nil }
        // Codex appends a native activity glyph even with session-id alone.
        // Discard that decoration; it is never used to infer activity.
        let text = title.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        if UUID(uuidString: text) != nil { return text.lowercased() }
        let suffix = text.hasSuffix("…") ? 1 : (text.hasSuffix("...") ? 3 : 0)
        guard suffix > 0 else { return nil }
        let value = String(text.dropLast(suffix)).lowercased()
        guard (20..<36).contains(value.utf8.count) else { return nil }
        let template = Array("00000000-0000-0000-0000-000000000000".utf8)
        for (index, byte) in value.utf8.enumerated() {
            if template[index] == 45 {
                guard byte == 45 else { return nil }
            } else if !(48...57).contains(byte) && !(97...102).contains(byte) { return nil }
        }
        return value
    }

    public static func resolve(prefix: String, loadedIDs: Set<String>) -> String? {
        let matches = loadedIDs.filter { UUID(uuidString: $0) != nil && $0.lowercased().hasPrefix(prefix) }
        return matches.count == 1 ? matches.first : nil
    }

    public func start() {
        guard lock.withLock({
            guard !started, !stopped else { return false }
            started = true
            return true
        }) else { return }
        Thread.detachNewThread { [self] in
            defer { socket.finish() }
            do {
                try socket.connect()
                try socket.sendJSON(["id": 1, "method": "initialize", "params": [
                    "clientInfo": ["name": "one_cli_title_observer", "version": "0.1"],
                    "capabilities": ["experimentalApi": true]]])
                while !lock.withLock({ stopped }) { try consume(socket.receiveJSON()) }
            } catch {
                lock.withLock { failure = String(describing: error) }
                publish(nil, "unknown")
            }
        }
    }

    public func stop() {
        lock.withLock { stopped = true }
        socket.cancel()
    }

    private func publish(_ id: String?, _ state: String) {
        guard !lock.withLock({ stopped }), lastState != state || lastThreadID != id else { return }
        lastState = state
        lastThreadID = id
        onState(id, state)
    }

    private func list(cursor: String? = nil) throws {
        guard cursors.count < 64 else { throw LocalWebSocket.Failure.oversized }
        var params: [String: Any] = ["limit": 100]
        if let cursor {
            guard cursor.utf8.count <= 4096, cursors.insert(cursor).inserted else { throw LocalWebSocket.Failure.invalidProtocol }
            params["cursor"] = cursor
        }
        listRequest = nextID
        nextID += 1
        try socket.sendJSON(["id": listRequest!, "method": "thread/loaded/list", "params": params])
    }

    private func bind() throws {
        guard !listing else { return }
        let resolved = Self.resolve(prefix: prefix, loadedIDs: loaded)
        guard resolved != threadID else { return }
        threadID = resolved
        publish(nil, "unknown")
        if let resolved {
            guard reads.count < 64 else { throw LocalWebSocket.Failure.oversized }
            let request = nextID
            nextID += 1
            reads[request] = resolved
            try socket.sendJSON(["id": request, "method": "thread/read", "params": ["threadId": resolved, "includeTurns": false]])
        }
    }

    private func consume(_ message: [String: Any]) throws {
        // A read-only client never responds to server requests or approvals.
        if message["method"] != nil, message["id"] != nil { return }
        if let method = message["method"] as? String, message["id"] == nil {
            let params = message["params"] as? [String: Any] ?? [:]
            if method == "thread/started", let thread = params["thread"] as? [String: Any],
               let id = thread["id"] as? String, UUID(uuidString: id) != nil {
                loaded.insert(id)
                if listing { added.insert(id); removed.remove(id) }
                try bind()
            } else if method == "thread/closed", let id = params["threadId"] as? String {
                loaded.remove(id)
                if listing { removed.insert(id); added.remove(id) }
                try bind()
            } else if method == "thread/status/changed", let id = params["threadId"] as? String,
                      id == threadID, !listing {
                reads = reads.filter { $0.value != id }
                publish(id, CodexDaemonObserver.state(params["status"] as? [String: Any] ?? [:]))
            }
            guard loaded.count + added.count + removed.count <= 4096 else { throw LocalWebSocket.Failure.oversized }
            return
        }
        guard let id = message["id"] as? Int else { return }
        guard message["error"] == nil, let result = message["result"] as? [String: Any] else {
            throw LocalWebSocket.Failure.invalidProtocol
        }
        if id == 1 {
            try socket.sendJSON(["method": "initialized", "params": [:]])
            try list()
        } else if id == listRequest {
            guard let ids = result["data"] as? [String], ids.allSatisfy({ UUID(uuidString: $0) != nil }),
                  loaded.count + ids.count <= 4096 else { throw LocalWebSocket.Failure.oversized }
            loaded.formUnion(ids)
            if let cursor = result["nextCursor"] as? String {
                try list(cursor: cursor)
            } else {
                loaded.formUnion(added)
                loaded.subtract(removed)
                added.removeAll(); removed.removeAll()
                listing = false
                try bind()
            }
        } else if let requested = reads.removeValue(forKey: id), requested == threadID {
            guard let thread = result["thread"] as? [String: Any], thread["id"] as? String == requested,
                  thread["parentThreadId"] is NSNull || thread["parentThreadId"] == nil,
                  (thread["source"] as? [String: Any])?["subagent"] == nil else {
                throw LocalWebSocket.Failure.invalidProtocol
            }
            publish(requested, CodexDaemonObserver.state(thread["status"] as? [String: Any] ?? [:]))
        }
    }
}
