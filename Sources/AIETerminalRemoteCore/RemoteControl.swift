import Foundation

public struct RemoteInputOutcome: Sendable, Equatable {
    public var requestId: String
    public var status: String
    public var bytes: Int
    public var reason: String
    public var leaseId: String

    public init(requestId: String, status: String, bytes: Int, reason: String, leaseId: String) {
        self.requestId = requestId
        self.status = status
        self.bytes = bytes
        self.reason = reason
        self.leaseId = leaseId
    }

    public func json() -> [String: Any] {
        [
            "requestId": requestId,
            "status": status,
            "bytes": bytes,
            "reason": reason,
            "leaseId": leaseId
        ]
    }
}

public final class RemoteControl: @unchecked Sendable {
    public enum Begin: Sendable {
        case fresh
        case replay(RemoteInputOutcome)
        case reject(RemoteInputOutcome)
    }

    private struct Entry {
        var digest: String
        var outcome: RemoteInputOutcome
        var at: Date
    }

    private let lock = NSLock()
    private var leaseId = ""
    private var sessionId = ""
    private var ptyGeneration: UInt64 = 0
    private var authVersion: UInt64 = 0
    private var leaseExpiry = Date.distantPast
    private var inflight = 0
    private var recent: [Date] = []
    private var ledger: [String: Entry] = [:]
    private var order: [String] = []
    private var retired: Set<String> = []
    private var retiredOrder: [String] = []
    private var abandoned: Set<String> = []
    private var abandonedOrder: [String] = []
    private var sending: Set<String> = []
    private var open: Set<String> = []

    private let clock: @Sendable () -> Date

    public init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
    }

    public func request(sessionId: String, ptyGeneration: UInt64, authVersion: UInt64) -> [String: Any] {
        lock.withLock {
            pruneLocked()
            expireLeaseLocked()
            if inflight >= 1, !leaseId.isEmpty {
                return ["status": "busy", "error": "busy"]
            }
            leaseId = randomHex(bytes: 16)
            self.sessionId = sessionId
            self.ptyGeneration = ptyGeneration
            self.authVersion = authVersion
            touchLeaseLocked()
            return [
                "status": "controlling",
                "leaseId": leaseId,
                "sessionId": sessionId,
                "ptyGeneration": String(ptyGeneration)
            ]
        }
    }

    public func snapshot() -> [String: Any] {
        lock.withLock {
            expireLeaseLocked()
            return [
                "status": leaseId.isEmpty ? "readonly" : "controlling",
                "sessionId": sessionId
            ]
        }
    }

    public func heartbeat(leaseId incoming: String) -> Bool {
        lock.withLock {
            expireLeaseLocked()
            guard !leaseId.isEmpty, incoming == leaseId else { return false }
            leaseExpiry = clock().addingTimeInterval(RemoteLimits.heartbeatSeconds)
            return true
        }
    }

    public func release() {
        lock.withLock { clearLeaseLocked() }
    }

    public func preempt() {
        lock.withLock { clearLeaseLocked() }
    }

    public func invalidate() {
        lock.withLock { clearLeaseLocked() }
    }

    public func expireLease() {
        lock.withLock {
            leaseExpiry = .distantPast
            expireLeaseLocked()
        }
    }

    public func evict(requestId: String) {
        lock.withLock {
            retireLocked(requestId)
            ledger.removeValue(forKey: requestId)
            order.removeAll { $0 == requestId }
        }
    }

    public func lookup(requestId: String) -> RemoteInputOutcome? {
        lock.withLock {
            pruneLocked()
            if retired.contains(requestId) {
                return RemoteInputOutcome(
                    requestId: requestId,
                    status: "unknown",
                    bytes: 0,
                    reason: "expired",
                    leaseId: leaseId
                )
            }
            return ledger[requestId]?.outcome
        }
    }

    public func stillValid(
        leaseId incoming: String,
        sessionId: String,
        ptyGeneration: UInt64,
        authVersion: UInt64
    ) -> Bool {
        lock.withLock {
            expireLeaseLocked()
            return matchesLocked(
                leaseId: incoming,
                sessionId: sessionId,
                ptyGeneration: ptyGeneration,
                authVersion: authVersion
            )
        }
    }

    public func abandon(requestId: String) -> Bool {
        lock.withLock {
            if sending.contains(requestId) { return false }
            if !open.contains(requestId),
               let entry = ledger[requestId],
               entry.outcome.status != "unknown" {
                return false
            }
            markAbandonedLocked(requestId)
            if var entry = ledger[requestId], entry.outcome.status == "unknown" {
                entry.outcome.status = "unknown"
                entry.outcome.reason = "timeout"
                entry.at = clock()
                ledger[requestId] = entry
                closeInflightLocked(requestId)
            }
            return true
        }
    }

    public func claimSend(requestId: String) -> Bool {
        lock.withLock {
            if abandoned.contains(requestId) { return false }
            sending.insert(requestId)
            return true
        }
    }

    public func begin(
        requestId: String,
        digest: String,
        leaseId incoming: String,
        sessionId: String,
        ptyGeneration: UInt64,
        authVersion: UInt64
    ) -> Begin {
        lock.withLock {
            pruneLocked()
            if abandoned.contains(requestId) {
                return .reject(RemoteInputOutcome(
                    requestId: requestId,
                    status: "unknown",
                    bytes: 0,
                    reason: "timeout",
                    leaseId: incoming
                ))
            }
            if retired.contains(requestId) {
                return .reject(RemoteInputOutcome(
                    requestId: requestId,
                    status: "unknown",
                    bytes: 0,
                    reason: "expired",
                    leaseId: incoming
                ))
            }
            if let entry = ledger[requestId] {
                if entry.digest == digest {
                    return .replay(entry.outcome)
                }
                return .reject(RemoteInputOutcome(
                    requestId: requestId,
                    status: "rejected",
                    bytes: 0,
                    reason: "mismatch",
                    leaseId: incoming
                ))
            }
            expireLeaseLocked()
            guard matchesLocked(
                leaseId: incoming,
                sessionId: sessionId,
                ptyGeneration: ptyGeneration,
                authVersion: authVersion
            ) else {
                return .reject(RemoteInputOutcome(
                    requestId: requestId,
                    status: "rejected",
                    bytes: 0,
                    reason: "no-control",
                    leaseId: incoming
                ))
            }
            let now = clock()
            recent = recent.filter { now.timeIntervalSince($0) < 1 }
            if recent.count >= RemoteLimits.inputPerSecond {
                return .reject(RemoteInputOutcome(
                    requestId: requestId,
                    status: "rejected",
                    bytes: 0,
                    reason: "limited",
                    leaseId: incoming
                ))
            }
            if inflight >= 1 {
                return .reject(RemoteInputOutcome(
                    requestId: requestId,
                    status: "rejected",
                    bytes: 0,
                    reason: "busy",
                    leaseId: incoming
                ))
            }
            recent.append(now)
            inflight += 1
            open.insert(requestId)
            leaseExpiry = now.addingTimeInterval(RemoteLimits.heartbeatSeconds)
            let pending = RemoteInputOutcome(
                requestId: requestId,
                status: "unknown",
                bytes: 0,
                reason: "",
                leaseId: incoming
            )
            storeLocked(requestId: requestId, digest: digest, outcome: pending)
            return .fresh
        }
    }

    public func finish(requestId: String, status: String, bytes: Int, reason: String) {
        lock.withLock {
            sending.remove(requestId)
            abandoned.remove(requestId)
            closeInflightLocked(requestId)
            if var entry = ledger[requestId] {
                entry.outcome.status = status
                entry.outcome.bytes = bytes
                entry.outcome.reason = reason
                entry.at = clock()
                ledger[requestId] = entry
            }
        }
    }

    public func digest(kind: String, text: String, key: String, modifiers: UInt32, enter: Bool) -> String {
        sha256("\(kind)|\(modifiers)|\(enter)|\(key)|\(text)")
    }

    private func matchesLocked(
        leaseId incoming: String,
        sessionId: String,
        ptyGeneration: UInt64,
        authVersion: UInt64
    ) -> Bool {
        !leaseId.isEmpty && incoming == leaseId && sessionId == self.sessionId
            && ptyGeneration == self.ptyGeneration && authVersion == self.authVersion
    }

    private func closeInflightLocked(_ requestId: String) {
        if open.remove(requestId) != nil, inflight > 0 {
            inflight -= 1
        }
    }

    private func clearLeaseLocked() {
        leaseId = ""
        sessionId = ""
        ptyGeneration = 0
        authVersion = 0
        leaseExpiry = .distantPast
    }

    private func touchLeaseLocked() {
        let now = clock()
        leaseExpiry = now.addingTimeInterval(RemoteLimits.heartbeatSeconds)
    }

    private func expireLeaseLocked() {
        guard !leaseId.isEmpty else { return }
        let now = clock()
        if now >= leaseExpiry {
            clearLeaseLocked()
        }
    }

    private func markAbandonedLocked(_ requestId: String) {
        guard abandoned.insert(requestId).inserted else { return }
        abandonedOrder.append(requestId)
        while abandonedOrder.count > RemoteLimits.ledgerCount {
            abandoned.remove(abandonedOrder.removeFirst())
        }
    }

    private func storeLocked(requestId: String, digest: String, outcome: RemoteInputOutcome) {
        ledger[requestId] = Entry(digest: digest, outcome: outcome, at: clock())
        order.append(requestId)
        pruneLocked()
    }

    private func retireLocked(_ requestId: String) {
        guard retired.insert(requestId).inserted else { return }
        retiredOrder.append(requestId)
        while retiredOrder.count > RemoteLimits.ledgerCount {
            let old = retiredOrder.removeFirst()
            retired.remove(old)
        }
    }

    private func pruneLocked() {
        let now = clock()
        while order.count > RemoteLimits.ledgerCount {
            let old = order.removeFirst()
            retireLocked(old)
            ledger.removeValue(forKey: old)
        }
        order.removeAll { id in
            guard let entry = ledger[id] else { return true }
            if now.timeIntervalSince(entry.at) > RemoteLimits.ledgerSeconds {
                retireLocked(id)
                ledger.removeValue(forKey: id)
                return true
            }
            return false
        }
    }
}
