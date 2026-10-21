import AIETerminalCore
import Darwin
import Foundation

enum LoginEnvironment {
    private static let cached = Task.detached(priority: .userInitiated) { snapshot() }

    static func cachedSnapshot() async -> [String: String] {
        await cached.value
    }

    static func snapshot(environment fallback: [String: String] = ProcessInfo.processInfo.environment, timeout: TimeInterval = 5) -> [String: String] {
        // Startup scripts can print or leave descendants holding stdout open.
        // Capture only env's output in a private file; discard startup chatter.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aie-login-\(UUID().uuidString)", isDirectory: true)
        let output = directory.appendingPathComponent("environment")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return fallback }
        } catch { return fallback }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "/usr/bin/env -0 > \"$1\"", "aie-login-environment", output.path]
        process.environment = fallback
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return fallback
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            _ = try? ProcessReaper.reap(root: process.processIdentifier, waitSeconds: 0.6, escalateAfter: 0.1)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return fallback
        }
        guard process.terminationStatus == 0,
              let handle = try? FileHandle(forReadingFrom: output) else { return fallback }
        defer { try? handle.close() }
        let limit = 1_048_576
        guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit else { return fallback }
        var environment: [String: String] = [:]
        for item in data.split(separator: 0, omittingEmptySubsequences: true) {
            guard let line = String(data: Data(item), encoding: .utf8),
                  let divider = line.firstIndex(of: "=")
            else { continue }
            let key = String(line[..<divider])
            let value = String(line[line.index(after: divider)...])
            if key.hasPrefix("AIE_") { continue }
            environment[key] = value
        }
        if environment["PATH"] == nil {
            return fallback
        }
        return environment
    }

    static func processArray(_ environment: [String: String]) -> [String] {
        environment.keys.sorted().compactMap { key in
            guard let value = environment[key] else { return nil }
            return "\(key)=\(value)"
        }
    }
}
