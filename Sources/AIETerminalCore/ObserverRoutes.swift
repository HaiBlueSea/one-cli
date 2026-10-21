import Foundation

public struct ObserverRoute: Codable, Equatable, Sendable {
    public var socket: String
    public var appRunID: String
    public var sessionID: String
    public var nonce: String
    public var ptyGeneration: UInt64
    public var launchID: String
    public var shellPID: Int32
    public var cwd: String
    public var launchStartedAt: TimeInterval?

    public init(socket: String, appRunID: String, sessionID: String, nonce: String, ptyGeneration: UInt64, launchID: String, shellPID: Int32, cwd: String, launchStartedAt: TimeInterval = Date().timeIntervalSince1970) {
        self.socket = socket
        self.appRunID = appRunID
        self.sessionID = sessionID
        self.nonce = nonce
        self.ptyGeneration = ptyGeneration
        self.launchID = launchID
        self.shellPID = shellPID
        self.cwd = cwd
        self.launchStartedAt = launchStartedAt
    }

    public func matches(environment: [String: String]) -> Bool {
        let identity = [
            "AIE_SOCKET": socket, "AIE_APP_RUN": appRunID,
            "AIE_SESSION": sessionID, "AIE_NONCE": nonce,
            "AIE_PTY_GEN": String(ptyGeneration), "AIE_LAUNCH_ID": launchID
        ]
        return identity.allSatisfy { key, value in
            environment[key] == nil || environment[key] == value
        }
    }
}

public enum ObserverRoutes {
    public static func directory(forSocket socketPath: String) -> URL? {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let name: String
        if socketPath.contains("/AITerminalDev/") {
            name = "AITerminalDev"
        } else if socketPath.contains("/AITerminalVerification/") {
            name = "AITerminalVerification"
        } else if socketPath.contains("/AITerminal/") {
            name = "AITerminal"
        } else {
            return nil
        }
        return base.appendingPathComponent(name).appendingPathComponent("routes", isDirectory: true)
    }

    public static func installedDirectories() -> [URL] {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return ["AITerminal", "AITerminalDev", "AITerminalVerification"].map {
            base.appendingPathComponent($0).appendingPathComponent("routes", isDirectory: true)
        }
    }

    public static func save(_ route: ObserverRoute, directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(route)
        try data.write(to: file(route.shellPID, directory: directory), options: .atomic)
    }

    public static func remove(shellPID: Int32, directory: URL) {
        try? FileManager.default.removeItem(at: file(shellPID, directory: directory))
    }

    public static func resolve(ancestorPIDs: [Int32], cwd: String?, directories: [URL]) -> ObserverRoute? {
        let loaded = directories.flatMap { loadAll(in: $0) }
        let live = loaded.filter { FileManager.default.fileExists(atPath: $0.socket) }
        for (index, pid) in ancestorPIDs.enumerated() {
            let matches = live.filter { $0.shellPID == pid }
            guard !matches.isEmpty else { continue }
            guard matches.count == 1, let started = matches[0].launchStartedAt,
                  started.isFinite, started >= 0 else { return nil }
            if index > 0 {
                // The Shell may outlive many launches. Its direct child, not
                // the newly spawned hook helper, must belong to this launch.
                guard let childStarted = processStartTime(ancestorPIDs[index - 1]), childStarted >= started else { return nil }
            }
            return matches[0]
        }
        // A shared directory or a single route cannot establish process ownership.
        return nil
    }

    public static func ancestorPIDs(startingAt pid: Int32) -> [Int32] {
        var current = pid
        var chain: [Int32] = []
        var seen = Set<Int32>()
        while current > 1, seen.insert(current).inserted, chain.count < 32 {
            chain.append(current)
            var info = proc_bsdinfo()
            let size = proc_pidinfo(current, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
            if size <= 0 { break }
            current = Int32(info.pbi_ppid)
        }
        return chain
    }

    private static func file(_ shellPID: Int32, directory: URL) -> URL {
        directory.appendingPathComponent("shell-\(shellPID).json")
    }

    private static func loadAll(in directory: URL) -> [ObserverRoute] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return names.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(ObserverRoute.self, from: data)
        }
    }

    private static func processStartTime(_ pid: Int32) -> TimeInterval? {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard size == MemoryLayout<proc_bsdinfo>.size else { return nil }
        return Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
    }

}
