import Darwin
import Foundation

/// A launch owns its daemon and configuration overlay, while history stays shared.
public enum CodexService {
    private struct Owner: Codable {
        let appRunID: String
        let sessionID: String
        let launchID: String
        let serviceID: String
        let ptyGeneration: UInt64?
        let sharedHistoryHome: String?
        let launchPID: pid_t?
        let launchStartToken: String?
        var preparing: Bool?
    }

    public static func root(flavor: AppFlavor, sessionID: String) throws -> URL {
        try RuntimePaths.supportDirectory(flavor: flavor)
            .appendingPathComponent("codex-services", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
    }

    public static func launch(cli: String, arguments: [String], environment: [String: String]) throws -> Int32 {
        let passthrough = arguments.contains("--help") || arguments.contains("-h") || arguments.contains("--version") || arguments.contains("-V")
        guard !passthrough, let rootPath = environment["AIE_CODEX_ROOT"],
              let appRunID = environment["AIE_APP_RUN"], let sessionID = environment["AIE_SESSION"] else {
            return try run(cli, arguments, environment)
        }
        let serviceID = UUID().uuidString
        let launchID = environment["AIE_LAUNCH_ID"] ?? serviceID
        let home = URL(fileURLWithPath: rootPath).appendingPathComponent(serviceID, isDirectory: true)
        let source = URL(fileURLWithPath: environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex").standardizedFileURL
        let fm = FileManager.default
        try fm.createDirectory(at: home.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        // exec replaces this process on success. Every returning failure removes
        // only the fresh overlay, including failures before links are complete.
        defer {
            try? fm.removeItem(at: home)
            try? removeEmptyDirectory(home.deletingLastPathComponent())
        }
        guard let process = try ProcessSnapshot.list().first(where: { $0.pid == getpid() }) else { throw POSIXError(.EIO) }
        var owner = Owner(appRunID: appRunID, sessionID: sessionID, launchID: launchID, serviceID: serviceID,
                          ptyGeneration: UInt64(environment["AIE_PTY_GEN"] ?? "1"), sharedHistoryHome: source.path,
                          launchPID: process.pid, launchStartToken: process.startToken, preparing: true)
        let ownerURL = home.appendingPathComponent("aie-owner.json")
        // Record recoverable ownership before copying any local credentials.
        try JSONEncoder().encode(owner).write(to: ownerURL, options: .atomic)
        try prepareHome(home, source: source)
        if let helper = environment["AIE_HELPER"] {
            let hooks = home.appendingPathComponent("hooks.json")
            let merged = try CodexObserverHooks.mergeJSON(try? Data(contentsOf: hooks), helperPath: helper)
            try merged.write(to: hooks, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: hooks.path)
        }
        owner.preparing = false
        try JSONEncoder().encode(owner).write(to: ownerURL, options: .atomic)
        var env = environment
        env["CODEX_HOME"] = home.path
        // SQLite contains persistent thread metadata/history. Daemon ownership
        // and control sockets are rooted in CODEX_HOME, not CODEX_SQLITE_HOME.
        // A configured sqlite_home still takes precedence, as in native Codex.
        env["CODEX_SQLITE_HOME"] = environment["CODEX_SQLITE_HOME"] ?? source.path
        return try run(cli, arguments, env)
    }

    private static func prepareHome(_ home: URL, source: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let files = (try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        for file in files {
            let name = file.lastPathComponent
            guard name.hasSuffix(".toml") || ["auth.json", "hooks.json"].contains(name) else { continue }
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let destination = home.appendingPathComponent(name)
            try fm.copyItem(at: file, to: destination)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
        for name in ["AGENTS.md", "AGENTS.override.md"] {
            try installResolvedFile(name, from: source, to: home)
        }
        // Codex rejects a symlinked skills/plugins root. Keep a real directory
        // and link each child, matching the entries in the original home.
        for name in ["skills", "agents", "rules", "plugins"] {
            try mirrorLinkedDirectory(name, from: source, to: home)
        }
        // Share only persisted conversations and their writer locks. Never
        // share daemon packages, service locks, control sockets or hook trust.
        for name in ["sessions", "archived_sessions", "thread-writer-locks"] {
            let path = source.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.createSymbolicLink(at: home.appendingPathComponent(name), withDestinationURL: path)
        }
        for name in ["history.jsonl", "session_index.jsonl"] {
            let path = source.appendingPathComponent(name)
            // O_EXCL avoids truncating an existing file if launches race.
            let descriptor = open(path.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            if descriptor >= 0 { close(descriptor) }
            else if errno != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try fm.createSymbolicLink(at: home.appendingPathComponent(name), withDestinationURL: path)
        }
    }

    private static func installResolvedFile(_ name: String, from source: URL, to home: URL) throws {
        let origin = source.appendingPathComponent(name)
        let resolved = origin.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: resolved.path) else { return }
        let data = try Data(contentsOf: resolved)
        let destination = home.appendingPathComponent(name)
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    private static func mirrorLinkedDirectory(_ name: String, from source: URL, to home: URL) throws {
        let fm = FileManager.default
        let origin = source.appendingPathComponent(name)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: origin.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        let destination = home.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for child in try fm.contentsOfDirectory(atPath: origin.path) where child != ".DS_Store" {
            try fm.createSymbolicLink(
                at: destination.appendingPathComponent(child),
                withDestinationURL: origin.appendingPathComponent(child)
            )
        }
    }

    public static func ownedRoots(root: URL, appRunID: String, sessionID: String, launchID: String? = nil, ptyGeneration: UInt64) throws -> [pid_t] {
        let homes = ownedHomes(root: root, appRunID: appRunID, sessionID: sessionID, launchID: launchID, ptyGeneration: ptyGeneration)
        guard !homes.isEmpty else { return [] }
        return try ProcessSnapshot.list().filter { process in
            homes.contains { runs(process, inside: $0, suffix: "packages/app-server-daemon/") }
        }.map(\.pid)
    }

    public static func observationSocket(root: URL, serviceID: String, appRunID: String, sessionID: String, launchID: String) -> URL? {
        guard UUID(uuidString: serviceID) != nil else { return nil }
        let home = root.appendingPathComponent(serviceID)
        guard let data = try? Data(contentsOf: home.appendingPathComponent("aie-owner.json")),
              let owner = try? JSONDecoder().decode(Owner.self, from: data),
              owner.serviceID == serviceID, owner.appRunID == appRunID,
              owner.sessionID == sessionID, owner.launchID == launchID else { return nil }
        let socket = home.appendingPathComponent("app-server-control/app-server-control.sock")
        return FileManager.default.fileExists(atPath: socket.path) ? socket : nil
    }

    /// Shared-history overlays are disposable once their launch and service
    /// have stopped. Legacy homes retain their private data; only packages go.
    public static func removeStoppedRuntimeCaches(root: URL, appRunID: String, sessionID: String, launchID: String? = nil, ptyGeneration: UInt64) throws {
        let homes = ownedHomes(root: root, appRunID: appRunID, sessionID: sessionID, launchID: launchID, ptyGeneration: ptyGeneration)
        guard !homes.isEmpty else { return }
        let processes = try cleanupSnapshot()
        for home in homes {
            guard let owner = readOwner(home), stopped(home, owner: owner, processes: processes) else { continue }
            if try removeSharedHome(home, owner: owner) { continue }
            let packages = home.appendingPathComponent("packages")
            if FileManager.default.fileExists(atPath: packages.path) {
                try FileManager.default.removeItem(at: packages)
            }
        }
        try removeEmptyDirectory(root)
    }

    /// A prompt ends one foreground launch, not the PTY. Reclaim only that
    /// launch's private daemons after its recorded CLI identity has exited.
    public static func reapStoppedLaunch(root: URL, appRunID: String, sessionID: String, launchID: String, ptyGeneration: UInt64) throws -> ReaperResult {
        let homes = ownedHomes(root: root, appRunID: appRunID, sessionID: sessionID, launchID: launchID, ptyGeneration: ptyGeneration)
        let processes = try cleanupSnapshot()
        let stoppedHomes = homes.filter { home in
            guard let owner = readOwner(home), owner.launchPID != nil, owner.launchStartToken != nil else { return false }
            return !processes.contains { $0.pid == owner.launchPID && $0.startToken == owner.launchStartToken }
        }
        let roots = processes.filter { process in stoppedHomes.contains { runs(process, inside: $0, suffix: "packages/app-server-daemon/") } }.map(\.pid)
        let result = try ProcessReaper.reap(roots: roots)
        if !result.timedOut {
            try removeStoppedRuntimeCaches(root: root, appRunID: appRunID, sessionID: sessionID, launchID: launchID, ptyGeneration: ptyGeneration)
        }
        return result
    }

    /// Startup recovery never stops processes or removes legacy private history.
    @discardableResult
    public static func removeStaleSharedHomes(root: URL, excludingAppRunID: String) throws -> Int {
        let fm = FileManager.default
        guard isDirectory(root) else { return 0 }
        let processes = try cleanupSnapshot()
        var removed = 0
        for session in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where isDirectory(session) {
            for home in try fm.contentsOfDirectory(at: session, includingPropertiesForKeys: nil) where isDirectory(home) {
                guard let owner = readOwner(home), owner.sessionID == session.lastPathComponent,
                      owner.appRunID != excludingAppRunID, owner.ptyGeneration != nil,
                      stopped(home, owner: owner, processes: processes) else { continue }
                if try removeSharedHome(home, owner: owner) { removed += 1 }
            }
            try removeEmptyDirectory(session)
        }
        return removed
    }

    private static func cleanupSnapshot() throws -> [ProcessIdentity] {
        let processes = try ProcessSnapshot.list()
        // A failed/denied ps must never look like proof that all owners exited.
        guard processes.contains(where: { $0.pid == getpid() }) else { throw POSIXError(.EIO) }
        return processes
    }

    private static func readOwner(_ home: URL) -> Owner? {
        guard isDirectory(home), let data = try? Data(contentsOf: home.appendingPathComponent("aie-owner.json")),
              let owner = try? JSONDecoder().decode(Owner.self, from: data),
              owner.serviceID == home.lastPathComponent, UUID(uuidString: owner.serviceID) != nil else { return nil }
        return owner
    }

    private static func stopped(_ home: URL, owner: Owner, processes: [ProcessIdentity]) -> Bool {
        !processes.contains {
            ($0.pid == owner.launchPID && $0.startToken == owner.launchStartToken)
                || runs($0, inside: home)
        }
    }

    private static func runs(_ process: ProcessIdentity, inside home: URL, suffix: String = "") -> Bool {
        if process.command.hasPrefix(home.path + "/" + suffix) { return true }
        // Directory enumeration can canonicalize /var into /private/var while
        // ps retains the launch spelling. Locate the owned UUID boundary before
        // resolving only the executable's directory; arguments are not paths.
        guard process.command.hasPrefix("/"),
              let boundary = process.command.range(of: "/" + home.lastPathComponent + "/" + suffix) else { return false }
        let commandHome = String(process.command[..<boundary.lowerBound]) + "/" + home.lastPathComponent
        var info = stat()
        guard lstat(commandHome, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return false }
        return URL(fileURLWithPath: commandHome).resolvingSymlinksInPath() == home.resolvingSymlinksInPath()
    }

    private static func removeSharedHome(_ home: URL, owner: Owner) throws -> Bool {
        guard let sourcePath = owner.sharedHistoryHome, owner.launchPID != nil, owner.launchStartToken != nil else { return false }
        let source = URL(fileURLWithPath: sourcePath).resolvingSymlinksInPath()
        guard source.path != home.path, !source.path.hasPrefix(home.path + "/") else { return false }
        let fm = FileManager.default
        // Preparing overlays cannot have hosted a CLI or private history yet.
        if owner.preparing != true {
            for name in ["sessions", "archived_sessions", "thread-writer-locks", "history.jsonl", "session_index.jsonl"] {
                let link = home.appendingPathComponent(name)
                guard let destination = try? fm.destinationOfSymbolicLink(atPath: link.path),
                      URL(fileURLWithPath: destination, relativeTo: home).resolvingSymlinksInPath()
                        == source.appendingPathComponent(name).resolvingSymlinksInPath() else { return false }
            }
        }
        // removeItem unlinks symlinks; it never traverses shared history/plugins.
        do { try fm.removeItem(at: home) }
        catch CocoaError.fileNoSuchFile { /* Another lifecycle cleanup won. */ }
        return true
    }

    private static func isDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func removeEmptyDirectory(_ url: URL) throws {
        guard isDirectory(url) else { return }
        // Atomic rmdir cannot erase a home created between the check and removal.
        if rmdir(url.path) != 0 && ![ENOENT, ENOTEMPTY, EEXIST].contains(errno) {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func ownedHomes(root: URL, appRunID: String, sessionID: String, launchID: String? = nil, ptyGeneration: UInt64) -> [URL] {
        let fm = FileManager.default
        guard isDirectory(root) else { return [] }
        let homes = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return homes.filter { home in
            guard let owner = readOwner(home),
                  owner.appRunID == appRunID, owner.sessionID == sessionID,
                  owner.serviceID == home.lastPathComponent,
                  owner.ptyGeneration == ptyGeneration,
                  launchID == nil || launchID == owner.launchID else { return false }
            return true
        }
    }

    private static func run(_ cli: String, _ arguments: [String], _ environment: [String: String]) throws -> Int32 {
        for (key, value) in environment { setenv(key, value, 1) }
        if environment["CODEX_SQLITE_HOME"] == nil { unsetenv("CODEX_SQLITE_HOME") }
        let pointers = ([cli] + arguments).map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        var argv = pointers + [nil]
        // Preserve the foreground process group and native PTY input semantics.
        argv.withUnsafeMutableBufferPointer { buffer in
            _ = execv(cli, buffer.baseAddress!)
        }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
