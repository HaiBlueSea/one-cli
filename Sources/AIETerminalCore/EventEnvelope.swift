import Foundation

public struct EventEnvelope: Codable, Sendable, Equatable {
    public var version: Int
    public var appRunID: String
    public var terminalSessionID: String
    public var ptyGeneration: UInt64
    public var launchID: String?
    public var providerSessionID: String?
    public var turnID: String?
    public var source: String
    public var kind: String
    public var nonce: String
    public var payload: [String: JSONValue]

    public init(
        version: Int = 1,
        appRunID: String,
        terminalSessionID: String,
        ptyGeneration: UInt64,
        launchID: String? = nil,
        providerSessionID: String? = nil,
        turnID: String? = nil,
        source: String,
        kind: String,
        nonce: String,
        payload: [String: JSONValue] = [:]
    ) {
        self.version = version
        self.appRunID = appRunID
        self.terminalSessionID = terminalSessionID
        self.ptyGeneration = ptyGeneration
        self.launchID = launchID
        self.providerSessionID = providerSessionID
        self.turnID = turnID
        self.source = source
        self.kind = kind
        self.nonce = nonce
        self.payload = payload
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }

    public static func decode(_ data: Data) throws -> EventEnvelope {
        try JSONDecoder().decode(EventEnvelope.self, from: data)
    }
}

public enum EventValidation: Sendable {
    public static func accept(_ envelope: EventEnvelope, identity: AppIdentity, sessionID: String?, ptyGeneration: UInt64?) -> Bool {
        guard envelope.version == 1 else { return false }
        guard envelope.appRunID == identity.appRunID else { return false }
        guard envelope.nonce == identity.nonce else { return false }
        if let sessionID, envelope.terminalSessionID != sessionID {
            return false
        }
        if let ptyGeneration, envelope.ptyGeneration != ptyGeneration {
            return false
        }
        return true
    }
}

public enum LaunchGate: Sendable {
    public static func acceptAgentEvent(currentLaunchID: String?, incomingLaunchID: String?) -> Bool {
        guard let currentLaunchID, let incomingLaunchID else { return false }
        return currentLaunchID == incomingLaunchID
    }
}
