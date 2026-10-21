import AIETerminalCore
import Darwin
import Foundation

@main
enum HookHelperMain {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let env = ProcessInfo.processInfo.environment
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--observe-native-codex", arguments.count >= 2 {
            do {
                exit(try NativeCodexBridge.launch(cli: arguments[1], arguments: Array(arguments.dropFirst(2)), environment: env))
            } catch {
                fputs("One Cli: Codex 启动失败：\(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        if arguments.first == "--prepare-kimi-home", arguments.count >= 3 {
            do {
                try KimiObserverHome.prepare(source: URL(fileURLWithPath: arguments[1]), overlay: URL(fileURLWithPath: arguments[2]), helperPath: CommandLine.arguments[0])
                print(URL(fileURLWithPath: arguments[2]).standardizedFileURL.path)
                exit(0)
            } catch {
                exit(1)
            }
        }
        if arguments.first == "--launch-codex", arguments.count >= 2 {
            do {
                exit(try CodexService.launch(cli: arguments[1], arguments: Array(arguments.dropFirst(2)), environment: env))
            } catch {
                fputs("One Cli: Codex 启动失败：\(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        let kind = flag("kind", in: arguments) ?? (arguments.contains("--agent") ? "agentEvent" : nil)
        let source = arguments.contains("--agent") ? "agent" : (env["AIE_SOURCE"] ?? "shell")
        var payload: [String: JSONValue] = [:]

        var allowCursorPrompt = false
        if arguments.contains("--agent") || kind == "agentEvent" {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            payload = HookPayloadFilter.extract(fromJSONData: data)
            allowCursorPrompt = payload["hook_event_name"]?.stringValue == "beforeSubmitPrompt"
            if let pid = ClaudeSessionStatus.owningPID(startingAt: getpid(), directory: ClaudeSessionStatus.defaultDirectory) {
                payload["session_pid"] = .int(Int(pid))
            }
            if let home = env["CODEX_HOME"], let root = env["AIE_CODEX_ROOT"], home.hasPrefix(root + "/") {
                let serviceID = URL(fileURLWithPath: home).lastPathComponent
                if UUID(uuidString: serviceID) != nil { payload["serviceID"] = .string(serviceID) }
            }
        } else if kind == "codexLaunch" {
            let home = env["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
            guard !home.isEmpty else { exit(0) }
            payload["codexHome"] = .string(URL(fileURLWithPath: home, isDirectory: true).standardizedFileURL.path)
        } else if kind == "preexec" {
            payload["codexHome"] = .string(env["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex")
            let data = FileHandle.standardInput.readDataToEndOfFile()
            let raw = String(data: data, encoding: .utf8) ?? ""
            if let name = ShellCommandName.parse(raw) {
                payload["commandName"] = .string(name)
            } else {
                payload["emptyRaw"] = .bool(raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            payload["role"] = .string(flag("role", in: arguments) ?? env["AIE_SHELL_ROLE"] ?? "unknown")
            if let name = payload["commandName"]?.stringValue, isAgentCommand(name) {
                saveRoute(env, shellPID: getppid(), cwd: env["PWD"] ?? "")
            }
        } else {
            if let cwd = flag("cwd", in: arguments) {
                payload["cwd"] = .string(cwd)
            }
            if let role = flag("role", in: arguments) ?? env["AIE_SHELL_ROLE"] {
                payload["role"] = .string(role)
            }
            if let seq = flag("seq", in: arguments), let value = Int(seq) {
                payload["seq"] = .int(value)
            }
            if let code = flag("exit", in: arguments), let value = Int(code) {
                payload["exit"] = .int(value)
            }
            if kind == "promptReady" {
                removeRoute(env, shellPID: getppid())
            }
        }

        if let logPath = env["AIE_EVENT_LOG"] {
            let line = "\(source)/\(kind ?? "unknown")/\(payload["hook_event_name"]?.stringValue ?? "")\n"
            if FileManager.default.fileExists(atPath: logPath),
               let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                FileManager.default.createFile(atPath: logPath, contents: Data(line.utf8))
            }
        }

        var socket = env["AIE_SOCKET"]
        var appRunID = env["AIE_APP_RUN"]
        var sessionID = env["AIE_SESSION"]
        var nonce = env["AIE_NONCE"]
        var ptyGeneration = UInt64(env["AIE_PTY_GEN"] ?? "")
        var launchID = env["AIE_LAUNCH_ID"]
        // Native Agent hooks may lose their environment. Shell events always
        // belong to their own PTY, including prompts with no active launch.
        if source == "agent",
           socket == nil || appRunID == nil || sessionID == nil || nonce == nil || ptyGeneration == nil || launchID == nil,
           let route = ObserverRoutes.resolve(
            ancestorPIDs: ObserverRoutes.ancestorPIDs(startingAt: getppid()),
            cwd: payload["cwd"]?.stringValue,
            directories: ObserverRoutes.installedDirectories()
           ), route.matches(environment: env) {
            socket = route.socket
            appRunID = route.appRunID
            sessionID = route.sessionID
            nonce = route.nonce
            ptyGeneration = route.ptyGeneration
            launchID = route.launchID
        }
        guard let socket, let appRunID, let sessionID, let nonce, let ptyGeneration else {
            if allowCursorPrompt {
                FileHandle.standardOutput.write(Data("{\"continue\":true}\n".utf8))
            }
            exit(0)
        }

        let envelope = EventEnvelope(
            appRunID: appRunID,
            terminalSessionID: sessionID,
            ptyGeneration: ptyGeneration,
            launchID: launchID,
            providerSessionID: payload["session_id"]?.stringValue,
            turnID: payload["turn_id"]?.stringValue ?? payload["generation_id"]?.stringValue,
            source: source,
            kind: kind ?? "unknown",
            nonce: nonce,
            payload: payload
        )
        _ = EventClient.send(envelope, socketPath: socket)
        if allowCursorPrompt {
            FileHandle.standardOutput.write(Data("{\"continue\":true}\n".utf8))
        }
        exit(0)
    }

    private static func flag(_ name: String, in arguments: [String]) -> String? {
        let token = "--\(name)"
        if let index = arguments.firstIndex(of: token), arguments.indices.contains(index + 1) {
            return arguments[index + 1]
        }
        if let match = arguments.first(where: { $0.hasPrefix("\(token)=") }) {
            return String(match.dropFirst(token.count + 1))
        }
        return nil
    }

    private static func isAgentCommand(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower == "agent" || lower == "cursor-agent" { return true }
        return ["codex", "kimi", "claude", "cursor"].contains { prefix in
            lower == prefix || (lower.hasPrefix(prefix) && lower.dropFirst(prefix.count).allSatisfy(\.isNumber))
        }
    }

    private static func saveRoute(_ env: [String: String], shellPID: Int32, cwd: String) {
        guard let socket = env["AIE_SOCKET"],
              let directory = ObserverRoutes.directory(forSocket: socket),
              let appRunID = env["AIE_APP_RUN"],
              let sessionID = env["AIE_SESSION"],
              let nonce = env["AIE_NONCE"],
              let ptyGeneration = UInt64(env["AIE_PTY_GEN"] ?? ""),
              let launchID = env["AIE_LAUNCH_ID"] else { return }
        let route = ObserverRoute(
            socket: socket,
            appRunID: appRunID,
            sessionID: sessionID,
            nonce: nonce,
            ptyGeneration: ptyGeneration,
            launchID: launchID,
            shellPID: shellPID,
            cwd: cwd
        )
        try? ObserverRoutes.save(route, directory: directory)
    }

    private static func removeRoute(_ env: [String: String], shellPID: Int32) {
        guard let socket = env["AIE_SOCKET"],
              let directory = ObserverRoutes.directory(forSocket: socket) else { return }
        ObserverRoutes.remove(shellPID: shellPID, directory: directory)
    }
}
