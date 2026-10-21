import CryptoKit
import Foundation
import Security

public enum RemoteLimits {
    public static let protocolVersion = 1
    public static let headerBytes = 8192
    public static let controlBytes = 8192
    public static let screenBytes = 1_048_576
    public static let ipcBytes = 1_048_576
    public static let challengeSeconds: TimeInterval = 120
    public static let sessionSeconds: TimeInterval = 7 * 24 * 3600
    public static let redeemPerMinute = 5
    public static let frameInterval: TimeInterval = 0.05
    public static let inputBytes = 64 * 1024
    public static let inputMessageBytes = 96 * 1024
    public static let ledgerCount = 512
    public static let ledgerSeconds: TimeInterval = 600
    public static let inputPerSecond = 60
    public static let heartbeatSeconds: TimeInterval = 90
}

public enum RemoteError: String, Error, Sendable {
    case unauthorized
    case expired
    case mismatch
    case limited
    case disabled
    case occupied
    case rejected
}

public struct RemoteSessionDTO: Sendable, Equatable {
    public var id: String
    public var cwd: String
    public var title: String
    public var state: String
    public var ptyGeneration: UInt64

    public init(id: String, cwd: String, title: String, state: String, ptyGeneration: UInt64) {
        self.id = id
        self.cwd = cwd
        self.title = title
        self.state = state
        self.ptyGeneration = ptyGeneration
    }

    public func json() -> [String: Any] {
        [
            "id": id,
            "cwd": cwd,
            "title": title,
            "state": state,
            "ptyGeneration": String(ptyGeneration)
        ]
    }
}

public struct RemoteScreenDTO: Sendable {
    public var revision: UInt64
    public var cols: Int
    public var rows: Int
    public var alternate: Bool
    public var cursorX: Int
    public var cursorY: Int
    public var cursorHidden: Bool
    public var lines: [String]

    public init(
        revision: UInt64,
        cols: Int,
        rows: Int,
        alternate: Bool,
        cursorX: Int,
        cursorY: Int,
        cursorHidden: Bool,
        lines: [String]
    ) {
        self.revision = revision
        self.cols = cols
        self.rows = rows
        self.alternate = alternate
        self.cursorX = cursorX
        self.cursorY = cursorY
        self.cursorHidden = cursorHidden
        self.lines = lines
    }

    public func json() -> [String: Any] {
        [
            "type": "snapshot",
            "revision": String(revision),
            "cols": cols,
            "rows": rows,
            "alternate": alternate,
            "cursor": ["x": cursorX, "y": cursorY, "hidden": cursorHidden],
            "lines": lines
        ]
    }
}

public final class RemoteAuthority: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public var enabled = false
        public var remoteRunID = ""
        public var confirmCode: String?
        public var pending = false
        public var authorized = false
        public var status = "off"
    }

    private let lock = NSLock()
    private var enabled = false
    private var remoteRunID = ""
    private var capability = ""
    private var challenge: String?
    private var challengeExpiry = Date.distantPast
    private var confirmCode: String?
    private var pendingToken: String?
    private var tokenHash: String?
    private var tokenExpiry = Date.distantPast
    private var authVersion: UInt64 = 0
    private var redeemTimes: [Date] = []
    private var confirmed = false

    public init() {}

    public func enable(runID: String, capability: String) {
        lock.withLock {
            enabled = true
            remoteRunID = runID
            self.capability = capability
            statusResetPairingLocked()
        }
    }

    public func disable() {
        lock.withLock {
            enabled = false
            remoteRunID = ""
            capability = ""
            tokenHash = nil
            confirmed = false
            authVersion += 1
            statusResetPairingLocked()
        }
    }

    public func beginPairing() -> (challenge: String, confirmCode: String)? {
        lock.withLock {
            guard enabled else { return nil }
            let challenge = randomHex(bytes: 16)
            let code = String(format: "%06d", Int.random(in: 0...999_999))
            self.challenge = challenge
            challengeExpiry = Date().addingTimeInterval(RemoteLimits.challengeSeconds)
            confirmCode = code
            pendingToken = randomHex(bytes: 32)
            confirmed = false
            return (challenge, code)
        }
    }

    public func redeem(challenge incoming: String) -> Result<[String: Any], RemoteError> {
        lock.withLock {
            guard enabled else { return .failure(.disabled) }
            let now = Date()
            redeemTimes = redeemTimes.filter { now.timeIntervalSince($0) < 60 }
            guard let challenge, incoming == challenge else {
                if redeemTimes.count >= RemoteLimits.redeemPerMinute { return .failure(.limited) }
                redeemTimes.append(now)
                return .failure(.mismatch)
            }
            guard now < challengeExpiry else { return .failure(.expired) }
            if confirmed, let token = pendingToken {
                self.challenge = nil
                return .success(["status": "ready", "token": token, "confirmCode": confirmCode ?? ""])
            }
            return .success(["status": "pending", "confirmCode": confirmCode ?? ""])
        }
    }

    public func confirmPairing() -> Bool {
        lock.withLock {
            if confirmed { return true }
            guard enabled, pendingToken != nil, Date() < challengeExpiry else { return false }
            confirmed = true
            if let token = pendingToken {
                tokenHash = sha256(token)
                tokenExpiry = Date().addingTimeInterval(RemoteLimits.sessionSeconds)
                authVersion += 1
            }
            return true
        }
    }

    public func denyPairing() {
        lock.withLock { statusResetPairingLocked() }
    }

    public func authorize(token: String) -> Bool {
        lock.withLock {
            guard enabled, let tokenHash, Date() < tokenExpiry else { return false }
            return sha256(token) == tokenHash
        }
    }

    public func revoke() {
        lock.withLock {
            tokenHash = nil
            pendingToken = nil
            confirmed = false
            authVersion += 1
            statusResetPairingLocked()
        }
    }

    public func acceptsCapability(_ value: String) -> Bool {
        lock.withLock { enabled && value == capability && !capability.isEmpty }
    }

    public func currentAuthVersion() -> UInt64 {
        lock.withLock { authVersion }
    }

    public func snapshot() -> Snapshot {
        lock.withLock {
            var item = Snapshot()
            item.enabled = enabled
            item.remoteRunID = remoteRunID
            item.confirmCode = confirmCode
            item.pending = challenge != nil && Date() < challengeExpiry && !confirmed
            item.authorized = tokenHash != nil && Date() < tokenExpiry
            item.status = !enabled ? "off" : (item.authorized ? "connected" : (item.pending ? "pairing" : "local"))
            return item
        }
    }

    private func statusResetPairingLocked() {
        challenge = nil
        confirmCode = nil
        pendingToken = nil
        confirmed = false
    }
}

public func remoteJSON(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object)
}

public func remoteObject(_ data: Data) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: data)
    guard let dictionary = object as? [String: Any] else { throw RemoteError.rejected }
    return dictionary
}

public func sha256(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

public func randomHex(bytes: Int) -> String {
    var buffer = [UInt8](repeating: 0, count: bytes)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &buffer)
    return buffer.map { String(format: "%02x", $0) }.joined()
}

public func encodeIPC(_ object: [String: Any]) throws -> Data {
    let data = try remoteJSON(object)
    guard data.count <= RemoteLimits.ipcBytes else { throw RemoteError.limited }
    var length = UInt32(data.count).bigEndian
    var payload = Data()
    payload.append(Data(bytes: &length, count: 4))
    payload.append(data)
    return payload
}

public func decodeIPCFrame(_ data: Data) throws -> [String: Any] {
    guard data.count >= 4 else { throw RemoteError.rejected }
    let length = data.prefix(4).withUnsafeBytes { Int($0.load(as: UInt32.self).bigEndian) }
    guard length > 0, length <= RemoteLimits.ipcBytes, data.count >= 4 + length else { throw RemoteError.limited }
    return try remoteObject(data.subdata(in: 4..<(4 + length)))
}
