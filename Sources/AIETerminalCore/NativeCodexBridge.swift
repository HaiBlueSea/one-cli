import Darwin
import Foundation

/// Launch-local, byte-preserving Unix transport to the user's native daemon.
/// It never handles approvals, creates threads, rewrites RPCs or owns the daemon.
public enum NativeCodexBridge {
    public static func shouldObserve(_ arguments: [String]) -> Bool {
        let localOptions = ["--no-daemon", "--remote", "--remote-auth-token-env", "--config", "--enable", "--disable", "--profile", "--dangerously-bypass-hook-trust", "--help", "--version", "-h", "-V", "-c", "-p"]
        for arg in arguments {
            if localOptions.contains(arg) || localOptions.contains(where: { $0.hasPrefix("--") && arg.hasPrefix($0 + "=") }) { return false }
            if arg.hasPrefix("-c"), arg.count > 2 { return false }
            if arg.hasPrefix("-p"), arg.count > 2 { return false }
        }
        let commands: Set<String> = ["agents", "exec", "e", "review", "login", "logout", "mcp", "plugin", "app-server", "remote-control", "app", "completion", "update", "doctor", "sandbox", "debug", "apply", "a", "resume", "queue", "archive", "delete", "migrate-rollouts", "unarchive", "fork", "cloud", "exec-server", "features", "help"]
        let withValue: Set<String> = ["-m", "--model", "-C", "--cd", "-i", "--image", "-s", "--sandbox", "-a", "--ask-for-approval", "--add-dir", "--local-provider"]
        var skip = false
        for arg in arguments {
            if skip { skip = false; continue }
            if withValue.contains(arg) { skip = true; continue }
            if arg == "--" { break }
            if arg.hasPrefix("-") { continue }
            if commands.contains(arg) { return arg == "resume" || arg == "fork" }
            break // Positional prompt, not a subcommand.
        }
        return true
    }

    public static func launch(cli: String, arguments: [String], environment: [String: String]) throws -> Int32 {
        let required = ["AIE_SOCKET", "AIE_APP_RUN", "AIE_SESSION", "AIE_NONCE", "AIE_PTY_GEN", "AIE_LAUNCH_ID"]
        guard shouldObserve(arguments), required.allSatisfy({ environment[$0]?.isEmpty == false }) else {
            return try replace(cli, arguments, environment)
        }
        let home = URL(fileURLWithPath: environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex")
        let nativeSocket = home.appendingPathComponent("app-server-control/app-server-control.sock")
        // Use the CLI's own startup mechanism, with no per-terminal credentials
        // inherited by the shared, long-lived service.
        guard try startDaemon(cli, environment) else { return try replace(cli, arguments, environment) }
        let bridge: BridgeTransport
        do { bridge = try BridgeTransport(upstream: nativeSocket, environment: environment) }
        catch {
            fputs("One Cli: 状态观察未连接，继续原生启动。\n", stderr)
            return try replace(cli, arguments, environment)
        }
        defer { bridge.stop() }
        bridge.start()
        var forwarded = ["--remote", "unix://" + bridge.path]
        if !arguments.contains(where: { $0 == "--cd" || $0.hasPrefix("--cd=") || $0.hasPrefix("-C") }) {
            // Explicit remote mode otherwise defaults to the daemon's cwd.
            forwarded += ["--cd", FileManager.default.currentDirectoryPath]
        }
        let child = try spawn(cli, forwarded + arguments, environment)
        var status: Int32 = 0
        while waitpid(child, &status, 0) < 0 {
            if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECHILD) }
        }
        return status & 127 == 0 ? (status >> 8) & 255 : 128 + (status & 127)
    }

    private static func startDaemon(_ cli: String, _ environment: [String: String]) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["app-server", "daemon", "start"]
        process.environment = environment.filter { !$0.key.hasPrefix("AIE_") && !$0.key.hasPrefix("_AIE_") }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + 25) == .timedOut {
            process.terminate()
            if done.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
            return false
        }
        return process.terminationStatus == 0
    }

    private static func spawn(_ cli: String, _ arguments: [String], _ environment: [String: String]) throws -> pid_t {
        let args = ([cli] + arguments).map { strdup($0) } + [nil]
        let env = environment.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { for item in args + env { if let item { free(item) } } }
        var pid: pid_t = 0
        let result = args.withUnsafeBufferPointer { argv in
            env.withUnsafeBufferPointer { envp in
                posix_spawn(&pid, cli, nil, nil, UnsafeMutablePointer(mutating: argv.baseAddress!), UnsafeMutablePointer(mutating: envp.baseAddress!))
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
        return pid
    }

    private static func replace(_ cli: String, _ arguments: [String], _ environment: [String: String]) throws -> Int32 {
        let args = ([cli] + arguments).map { strdup($0) } + [nil]
        let env = environment.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { for item in args + env { if let item { free(item) } } }
        args.withUnsafeBufferPointer { argv in
            env.withUnsafeBufferPointer { envp in
                _ = execve(cli, UnsafeMutablePointer(mutating: argv.baseAddress!), UnsafeMutablePointer(mutating: envp.baseAddress!))
            }
        }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

private final class BridgePublisher: @unchecked Sendable {
    private let lock = NSLock()
    private let environment: [String: String]
    private let bridgeID = UUID().uuidString
    private let started = DispatchTime.now().uptimeNanoseconds
    private var sequence: UInt64 = 0
    private var pending: EventEnvelope?
    private var sending = false
    private let sent = DispatchGroup()

    init(environment: [String: String]) { self.environment = environment }

    func update(threadID: String?, state: String) {
        lock.lock()
        sequence += 1
        pending = EventEnvelope(
            appRunID: environment["AIE_APP_RUN"]!, terminalSessionID: environment["AIE_SESSION"]!,
            ptyGeneration: UInt64(environment["AIE_PTY_GEN"]!) ?? 0,
            launchID: environment["AIE_LAUNCH_ID"], providerSessionID: threadID,
            source: "agent", kind: "codexNativeState", nonce: environment["AIE_NONCE"]!,
            payload: ["state": .string(state), "bridgeID": .string(bridgeID),
                      "started": .string(String(started)), "sequence": .string(String(sequence)),
                      "bridgePID": .int(Int(getpid()))]
        )
        let start = !sending
        if start { sent.enter() }
        sending = true
        lock.unlock()
        if start { DispatchQueue.global(qos: .utility).async { self.drain() } }
    }

    private func drain() {
        defer { sent.leave() }
        while true {
            let next: EventEnvelope? = lock.withLock {
                guard let result = pending else { sending = false; return nil }
                pending = nil
                return result
            }
            guard let next else { return }
            _ = EventClient.send(next, socketPath: environment["AIE_SOCKET"]!)
        }
    }

    func flush() { _ = sent.wait(timeout: .now() + .milliseconds(500)) }
}

private final class BridgeTransport: @unchecked Sendable {
    let path: String
    private let directory: URL
    private let upstream: String
    private let listener: Int32
    private var wake = [Int32](repeating: -1, count: 2)
    private let lock = NSLock()
    private var stopped = false
    private var channels = Set<Int32>()
    private let workers = DispatchGroup()
    private let publisher: BridgePublisher
    private let binding: CodexConnectionBinding

    init(upstream: URL, environment: [String: String]) throws {
        let directory = URL(fileURLWithPath: "/private/tmp/aie-cb-" + UUID().uuidString.prefix(12))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        self.directory = directory
        path = directory.appendingPathComponent("cli.sock").path
        self.upstream = directory.appendingPathComponent("native.sock").path
        publisher = BridgePublisher(environment: environment)
        let publisher = self.publisher
        binding = CodexConnectionBinding { id, state in publisher.update(threadID: id, state: state) }
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        do {
            guard listener >= 0 else { throw POSIXError(.ENFILE) }
            try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("native.sock"), withDestinationURL: upstream)
            var address = try Self.address(path)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard result == 0, listen(listener, 8) == 0,
                  socketpair(AF_UNIX, SOCK_STREAM, 0, &wake) == 0 else { throw POSIXError(.EIO) }
            _ = fcntl(listener, F_SETFL, O_NONBLOCK)
            for fd in [listener] + wake { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        } catch {
            if listener >= 0 { close(listener) }
            for fd in wake where fd >= 0 { close(fd) }
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func start() {
        publisher.update(threadID: nil, state: "unknown")
        workers.enter()
        Thread.detachNewThread { [self] in
            defer { workers.leave() }
            var serial = 0
            while !lock.withLock({ stopped }) {
                var polls = [pollfd(fd: listener, events: Int16(POLLIN), revents: 0), pollfd(fd: wake[0], events: Int16(POLLIN), revents: 0)]
                let result = poll(&polls, 2, -1)
                if result < 0 { if errno == EINTR { continue }; break }
                if polls[1].revents != 0 { break }
                if polls[0].revents & Int16(POLLIN) == 0 { continue }
                let client = accept(listener, nil, nil)
                guard client >= 0 else { continue }
                // Darwin inherits the listener's nonblocking flag on accept.
                _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL, 0) & ~O_NONBLOCK)
                var uid: uid_t = 0; var gid: gid_t = 0
                var peerPID: pid_t = 0
                var peerSize = socklen_t(MemoryLayout<pid_t>.size)
                guard getpeereid(client, &uid, &gid) == 0, uid == getuid(),
                      getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &peerSize) == 0,
                      ObserverRoutes.ancestorPIDs(startingAt: peerPID).contains(getpid()),
                      lock.withLock({ !stopped && channels.count < 16 }) else { close(client); continue }
                let server = socket(AF_UNIX, SOCK_STREAM, 0)
                guard server >= 0 else { close(client); continue }
                do {
                    var address = try Self.address(upstream)
                    let connected = withUnsafePointer(to: &address) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
                    }
                    guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
                } catch { close(client); close(server); continue }
                for fd in [client, server] {
                    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
                    var yes: Int32 = 1
                    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
                }
                let accepted = lock.withLock {
                    guard !stopped else { return false }
                    channels.insert(client); channels.insert(server)
                    return true
                }
                guard accepted else { close(client); close(server); break }
                serial += 1
                let connection = serial
                let pair = DispatchGroup()
                for (input, output, fromClient) in [(client, server, true), (server, client, false)] {
                    workers.enter()
                    pair.enter()
                    Thread.detachNewThread { [self] in
                        defer { pair.leave(); workers.leave() }
                        pump(input: input, output: output, fromClient: fromClient, connection: connection)
                        shutdown(input, SHUT_RDWR); shutdown(output, SHUT_RDWR)
                    }
                }
                // Wait for both directions before releasing descriptors. Other
                // accepted connections remain independent and bounded.
                workers.enter()
                Thread.detachNewThread { [self] in
                    defer { workers.leave() }
                    pair.wait()
                    binding.disconnected(connection)
                    lock.withLock {
                        channels.remove(client); channels.remove(server)
                        close(client); close(server)
                    }
                }
            }
        }
    }

    private func pump(input: Int32, output: Int32, fromClient: Bool, connection: Int) {
        var observer = CodexWireObserver(masked: fromClient)
        var bytes = [UInt8](repeating: 0, count: 16 * 1024)
        while !lock.withLock({ stopped }) {
            let count = read(input, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            let data = Data(bytes.prefix(count))
            observer.consume(data) { message in
                if fromClient { binding.client(message, connection: connection) }
                else { binding.server(message, connection: connection) }
            }
            var sent = 0
            while sent < count {
                let amount = bytes.withUnsafeBytes { Darwin.write(output, $0.baseAddress! + sent, count - sent) }
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else { return }
                sent += amount
            }
        }
        binding.disconnected(connection)
    }

    func stop() {
        let shouldStop = lock.withLock {
            guard !stopped else { return false }
            stopped = true
            for fd in channels { shutdown(fd, SHUT_RDWR) }
            return true
        }
        guard shouldStop else { return }
        var byte: UInt8 = 1
        _ = write(wake[1], &byte, 1)
        workers.wait()
        publisher.flush()
        for fd in channels { close(fd) }
        close(listener)
        for fd in wake { close(fd) }
        try? FileManager.default.removeItem(at: directory)
    }

    private static func address(_ path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        guard bytes.count < 104 else { throw POSIXError(.ENAMETOOLONG) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
        }
        return address
    }
}
