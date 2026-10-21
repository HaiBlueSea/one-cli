import AIETerminalCore
import AIETerminalRemoteCore
import AppKit
import CoreImage
import Darwin
import Foundation
import SwiftTerm

@MainActor
final class RemoteService: ObservableObject {
    @Published var status = "关闭"
    @Published var url = ""
    @Published var confirmCode = ""
    @Published var qrImage: NSImage?
    @Published var enabled = false
    @Published var note = ""
    var allowQuickTunnel = false
    var autoQuickTunnel = false

    let authority = RemoteAuthority()
    let control = RemoteControl()
    private weak var coordinator: SessionCoordinator?
    private let identity: AppIdentity
    private var helper: Process?
    private var tunnel: Process?
    private var tunnelPipe: Pipe?
    private var helperRestartID = UUID()
    private var helperStopTask: Task<Void, Never>?
    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "com.aiterminal.remote.ipc")
    private var socketPath = ""
    private var capability = ""
    private var publicHost = ""
    private var ipc: IPCServer?

    init(identity: AppIdentity, coordinator: SessionCoordinator? = nil) {
        self.identity = identity
        self.coordinator = coordinator
    }

    func bind(coordinator: SessionCoordinator) {
        self.coordinator = coordinator
    }

    func toggle() {
        if enabled { disable() } else { enable() }
    }

    func enable() {
        do {
            let runID = UUID().uuidString
            capability = randomHex(bytes: 16)
            let ipcDirectory = try RuntimePaths.supportDirectory(flavor: identity.flavor)
                .appendingPathComponent("ipc", isDirectory: true)
            try FileManager.default.createDirectory(at: ipcDirectory, withIntermediateDirectories: true)
            socketPath = ipcDirectory.appendingPathComponent("remote-\(identity.appRunID.prefix(8)).sock").path
            if autoQuickTunnel {
                allowQuickTunnel = true
            } else if let pending = pendingPublicOrigin(), let host = URL(string: pending)?.host?.lowercased(), !host.isEmpty {
                allowQuickTunnel = true
                publicHost = host
            }
            authority.enable(runID: runID, capability: capability)
            try startIPC()
            if let stopping = helperStopTask {
                startHelperAfterStopping(stopping)
            } else {
                try startHelper()
            }
            refreshPairing()
            enabled = true
            if autoQuickTunnel {
                startQuickTunnel()
                status = "本机可用／外网启动中"
                note = "正在打开临时外网，二维码就绪后请用手机扫码。"
            } else {
                applyPendingPublicOrigin()
                status = publicHost.isEmpty ? "本机可用" : "本机可用／外网已接入"
                note = publicHost.isEmpty ? "" : "已加上外网入口，本机 127.0.0.1 仍可用。"
            }
            attachOutputs()
        } catch {
            disable()
            note = "远程未能启动：端口或 IPC 被占用。"
            status = "错误"
        }
    }

    func disable() {
        helperRestartID = UUID()
        authority.disable()
        control.invalidate()
        ipc = nil
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        unlink(socketPath)
        if let helper {
            helper.terminationHandler = nil
            // Deliver the signal before App termination; only waiting runs off-main.
            if helper.isRunning { helper.terminate() }
            let earlier = helperStopTask
            helperStopTask = Task {
                await earlier?.value
                await Self.stopHelper(helper)
            }
            self.helper = nil
        }
        stopQuickTunnel()
        enabled = false
        status = "关闭"
        url = ""
        confirmCode = ""
        publicHost = ""
        qrImage = nil
        detachOutputs()
    }

    func confirm() {
        if authority.confirmPairing() {
            status = "已连接"
            confirmCode = ""
            note = "手机已授权。输入需在手机请求控制。"
        }
    }

    func deny() {
        authority.denyPairing()
        refreshPairing()
        note = "已拒绝本次配对。"
    }

    func revoke() {
        authority.revoke()
        control.invalidate()
        refreshPairing()
        status = enabled ? (allowQuickTunnel ? "本机可用／外网待接入" : "本机可用") : "关闭"
        note = "已撤销授权。"
    }

    func helperProcessIdentifier() -> Int32? {
        helper?.processIdentifier
    }

    func adoptPublicOrigin(_ origin: String) {
        allowQuickTunnel = true
        let challenge = url.split(separator: "#").dropFirst().first.map(String.init) ?? ""
        let token = challenge.hasPrefix("c=") ? String(challenge.dropFirst(2)) : ""
        guard !token.isEmpty else { return }
        let root = origin.hasSuffix("/") ? String(origin.dropLast()) : origin
        guard let host = URL(string: root)?.host?.lowercased(), !host.isEmpty else { return }
        let already = publicHost == host
        url = "\(root)/#c=\(token)"
        qrImage = makeQR(url)
        status = confirmCode.isEmpty ? "本机可用／外网已接入" : "等待确认 \(confirmCode)"
        note = "已加上外网入口，本机 127.0.0.1 仍可用。"
        if !already {
            publicHost = host
            if enabled {
                restartHelper()
            }
        }
    }

    func applyPendingPublicOrigin() {
        guard enabled, !autoQuickTunnel, let origin = pendingPublicOrigin() else { return }
        adoptPublicOrigin(origin)
    }

    func attach(_ host: TerminalHost) {
        guard enabled else { return }
        host.view.setUserInputObserver { [weak self] in
            Task { @MainActor in
                guard let self, self.enabled else { return }
                self.control.preempt()
            }
        }
    }

    func attachOutputs() {
        coordinator?.sessions.forEach { session in
            attach(session.host)
        }
    }

    private func pendingPublicOrigin() -> String? {
        guard let file = try? RuntimePaths.supportDirectory(flavor: identity.flavor).appendingPathComponent("public-origin.txt"),
              let raw = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let origin = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard origin.hasPrefix("https://"), URL(string: origin)?.host != nil else { return nil }
        return origin.hasSuffix("/") ? String(origin.dropLast()) : origin
    }

    private func refreshPairing() {
        guard let pair = authority.beginPairing() else { return }
        let port = identity.flavor.remotePort
        url = "http://127.0.0.1:\(port)/#c=\(pair.challenge)"
        confirmCode = pair.confirmCode
        qrImage = makeQR(url)
        status = "等待确认 \(pair.confirmCode)"
        if enabled, !publicHost.isEmpty {
            adoptPublicOrigin("https://\(publicHost)")
        } else if enabled {
            applyPendingPublicOrigin()
        }
    }

    private func startQuickTunnel() {
        stopQuickTunnel()
        guard let binary = BundledCloudflared.executableURL() else {
            note = "本机可用。应用内置 cloudflared 缺失或不可执行，请重新安装应用。"
            status = "本机可用"
            return
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "tunnel",
            "--url", "http://127.0.0.1:\(identity.flavor.remotePort)",
            "--no-autoupdate"
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor in
                guard let self, self.enabled, finished === self.tunnel else { return }
                self.note = "外网隧道已断开，本机远程仍可用。"
            }
        }
        do {
            try process.run()
        } catch {
            note = "临时外网未能启动，本机 127.0.0.1 仍可用。"
            status = "本机可用"
            return
        }
        tunnel = process
        tunnelPipe = pipe
        let addressReader = TunnelAddressReader()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            // After finding the address, keep draining and discard all log output.
            guard let origin = addressReader.consume(chunk) else { return }
            Task { @MainActor in
                guard let self, self.enabled, self.tunnel === process else { return }
                self.adoptPublicOrigin(origin)
            }
        }
    }

    private func stopQuickTunnel() {
        tunnelPipe?.fileHandleForReading.readabilityHandler = nil
        tunnelPipe = nil
        if let tunnel {
            tunnel.terminationHandler = nil
            tunnel.terminate()
            let process = tunnel
            self.tunnel = nil
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
            }
        }
    }

    private func startHelper() throws {
        let process = Process()
        process.executableURL = ResourceLocator.remoteHelperURL()
        var arguments = [
            "--socket", socketPath,
            "--token", capability,
            "--port", "\(identity.flavor.remotePort)",
            "--root", ResourceLocator.remoteWebDirectory().path
        ]
        if allowQuickTunnel, !publicHost.isEmpty {
            arguments += ["--allow-host", publicHost]
        }
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor in
                guard let self, self.enabled, finished === self.helper else { return }
                self.control.invalidate()
                self.note = "远程 helper 已退出，本机终端未受影响。"
                self.status = "helper 退出"
            }
        }
        try process.run()
        helper = process
        if !process.isRunning { throw RemoteError.occupied }
    }

    private func restartHelper() {
        let previous = helper
        previous?.terminationHandler = nil
        if let previous, previous.isRunning { previous.terminate() }
        helper = nil
        control.invalidate()
        let earlier = helperStopTask
        let stopping = Task {
            await earlier?.value
            if let previous { await Self.stopHelper(previous) }
        }
        helperStopTask = stopping
        startHelperAfterStopping(stopping)
    }

    private func startHelperAfterStopping(_ stopping: Task<Void, Never>) {
        let restartID = UUID()
        helperRestartID = restartID
        Task { [weak self] in
            await stopping.value
            guard let self, self.enabled, self.helperRestartID == restartID else { return }
            self.helperStopTask = nil
            do {
                try self.startHelper()
            } catch {
                self.note = "外网入口已记录，helper 未能按该主机重启。"
                self.status = "错误"
            }
        }
    }

    private nonisolated static func stopHelper(_ process: Process) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                if process.isRunning { process.terminate() }
                let deadline = Date().addingTimeInterval(2)
                while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                continuation.resume()
            }
        }
    }

    private func startIPC() throws {
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RemoteError.occupied }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            for (index, byte) in path.enumerated() { buffer[index] = byte }
        }
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            close(fd)
            throw RemoteError.occupied
        }
        chmod(socketPath, S_IRUSR | S_IWUSR)
        listenFD = fd
        let server = IPCServer(authority: authority, control: control, owner: self)
        ipc = server
        queue.async {
            while true {
                var addr = sockaddr_un()
                var length = socklen_t(MemoryLayout<sockaddr_un>.size)
                let client = withUnsafeMutablePointer(to: &addr) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.accept(fd, $0, &length)
                    }
                }
                if client < 0 { break }
                server.serve(client)
            }
        }
    }

    fileprivate func sessionPayload() -> [String: Any] {
        ["sessions": coordinator?.remoteSessions().map { $0.json() } ?? [], "language": L10n.shared.language.rawValue]
    }

    fileprivate func screenPayload(sessionID: String, since: UInt64) -> [String: Any] {
        coordinator?.remoteScreen(sessionID: sessionID, since: since) ?? ["error": "missing"]
    }

    fileprivate func controlPayload(sessionID: String) -> [String: Any] {
        guard let session = coordinator?.sessions.first(where: { $0.id == sessionID }) else {
            return ["error": "missing", "status": "rejected"]
        }
        return control.request(
            sessionId: session.id,
            ptyGeneration: session.host.ptyGeneration,
            authVersion: authority.currentAuthVersion()
        )
    }

    fileprivate func startInput(_ message: [String: Any], finish: @escaping @Sendable ([String: Any]) -> Void) {
        let requestId = message["requestId"] as? String ?? ""
        let leaseId = message["leaseId"] as? String ?? ""
        let sessionID = message["sessionId"] as? String ?? ""
        let kind = message["kind"] as? String ?? "text"
        let text = message["text"] as? String ?? ""
        let key = message["key"] as? String ?? ""
        let modifiers = UInt32(message["modifiers"] as? Int ?? 0)
        let enter = message["enter"] as? Bool ?? false
        guard !requestId.isEmpty else {
            finish(RemoteInputOutcome(requestId: "", status: "rejected", bytes: 0, reason: "missing-id", leaseId: leaseId).json())
            return
        }
        guard let session = coordinator?.sessions.first(where: { $0.id == sessionID }) else {
            finish(RemoteInputOutcome(requestId: requestId, status: "rejected", bytes: 0, reason: "missing", leaseId: leaseId).json())
            return
        }
        let digest = control.digest(kind: kind, text: text, key: key, modifiers: modifiers, enter: enter)
        switch control.begin(
            requestId: requestId,
            digest: digest,
            leaseId: leaseId,
            sessionId: sessionID,
            ptyGeneration: session.host.ptyGeneration,
            authVersion: authority.currentAuthVersion()
        ) {
        case .replay(let outcome):
            finish(outcome.json())
            return
        case .reject(let outcome):
            finish(outcome.json())
            return
        case .fresh:
            break
        }
        let encoded: [UInt8]?
        switch kind {
        case "paste":
            encoded = encodePaste(session.host, text: text, enter: enter)
        case "key":
            encoded = encodeKey(session.host, key: key, modifiers: modifiers)
        default:
            encoded = encodeText(session.host, text: text, enter: enter)
        }
        guard let encoded else {
            control.finish(requestId: requestId, status: "rejected", bytes: 0, reason: "invalid")
            finish(RemoteInputOutcome(requestId: requestId, status: "rejected", bytes: 0, reason: "invalid", leaseId: leaseId).json())
            return
        }
        if encoded.count > RemoteLimits.inputBytes {
            control.finish(requestId: requestId, status: "rejected", bytes: 0, reason: "limited")
            finish(RemoteInputOutcome(requestId: requestId, status: "rejected", bytes: 0, reason: "limited", leaseId: leaseId).json())
            return
        }
        guard control.stillValid(
            leaseId: leaseId,
            sessionId: sessionID,
            ptyGeneration: session.host.ptyGeneration,
            authVersion: authority.currentAuthVersion()
        ) else {
            control.finish(requestId: requestId, status: "rejected", bytes: 0, reason: "no-control")
            finish(RemoteInputOutcome(requestId: requestId, status: "rejected", bytes: 0, reason: "no-control", leaseId: leaseId).json())
            return
        }
        guard control.claimSend(requestId: requestId) else {
            finish(RemoteInputOutcome(requestId: requestId, status: "unknown", bytes: 0, reason: "timeout", leaseId: leaseId).json())
            return
        }
        let control = self.control
        session.host.sendBytes(encoded) { result in
            let outcome: RemoteInputOutcome
            switch result {
            case .success(let count):
                outcome = RemoteInputOutcome(requestId: requestId, status: "written", bytes: count, reason: "", leaseId: leaseId)
            case .failure(.notRunning):
                outcome = RemoteInputOutcome(requestId: requestId, status: "rejected", bytes: 0, reason: "not-running", leaseId: leaseId)
            case .failure(.writeFailed(_, let written)):
                outcome = written > 0
                    ? RemoteInputOutcome(requestId: requestId, status: "partial", bytes: written, reason: "write-failed", leaseId: leaseId)
                    : RemoteInputOutcome(requestId: requestId, status: "rejected", bytes: 0, reason: "write-failed", leaseId: leaseId)
            case .failure:
                outcome = RemoteInputOutcome(requestId: requestId, status: "rejected", bytes: 0, reason: "write-failed", leaseId: leaseId)
            }
            control.finish(requestId: requestId, status: outcome.status, bytes: outcome.bytes, reason: outcome.reason)
            finish(outcome.json())
        }
    }

    private func encodeText(_ host: TerminalHost, text: String, enter: Bool) -> [UInt8]? {
        if text.utf8.count > RemoteLimits.inputBytes { return nil }
        if text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) { return nil }
        var bytes = host.view.encodeRemoteText(text) ?? []
        if enter { bytes.append(0x0d) }
        if bytes.isEmpty && !enter { return nil }
        return bytes
    }

    private func encodePaste(_ host: TerminalHost, text: String, enter: Bool) -> [UInt8]? {
        if text.utf8.count > RemoteLimits.inputBytes { return nil }
        if text.utf8.contains(where: { byte in
            byte != 0x09 && byte != 0x0a && byte != 0x0d
                && (byte < 0x20 || byte == 0x7f
                    || TerminalPasteControls.fixedDisallowedBytes.contains(byte)
                    || TerminalPasteControls.approximateTerminalControlBytes.contains(byte))
        }) {
            return nil
        }
        guard var bytes = host.view.encodeRemotePaste(text) else { return nil }
        if enter { bytes.append(0x0d) }
        return bytes
    }

    private func encodeKey(_ host: TerminalHost, key: String, modifiers: UInt32) -> [UInt8]? {
        let allowed = [
            "Escape", "Enter", "Tab", "Backspace", "Delete",
            "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight",
            "Home", "End", "c", "C", "d", "D"
        ]
        guard allowed.contains(key) else { return nil }
        if (key == "c" || key == "C" || key == "d" || key == "D") && modifiers & 4 == 0 {
            return nil
        }
        return host.view.encodeRemoteKey(name: key, code: key, modifiers: modifiers)
    }

    private func detachOutputs() {
        coordinator?.sessions.forEach {
            $0.host.view.setProcessOutputHandler(nil)
            $0.host.view.setUserInputObserver(nil)
        }
    }
}

private final class IPCServer: @unchecked Sendable {
    let authority: RemoteAuthority
    let control: RemoteControl
    weak var owner: RemoteService?

    init(authority: RemoteAuthority, control: RemoteControl, owner: RemoteService) {
        self.authority = authority
        self.control = control
        self.owner = owner
    }

    func serve(_ client: Int32) {
        defer { close(client) }
        do {
            let hello = try readJSON(client)
            let token = hello["token"] as? String ?? ""
            guard authority.acceptsCapability(token) else { return }
            try writeJSON(client, ["v": 1, "type": "hello-ok"])
            while let message = try? readJSON(client) {
                try writeJSON(client, handle(message))
            }
        } catch {
            return
        }
    }

    private func handle(_ message: [String: Any]) -> [String: Any] {
        switch message["type"] as? String ?? "" {
        case "language":
            return onMain { _ in ["language": L10n.shared.language.rawValue] }
        case "pair":
            var reply: [String: Any]
            switch authority.redeem(challenge: message["challenge"] as? String ?? "") {
            case .success(let payload):
                reply = payload
            case .failure(let error):
                reply = ["status": "error", "error": error.rawValue]
            }
            reply["language"] = onMain { _ in ["language": L10n.shared.language.rawValue] }["language"]
            return reply
        case "sessions":
            guard authority.authorize(token: message["token"] as? String ?? "") else {
                return ["error": "unauthorized"]
            }
            return onMain { $0.sessionPayload() }
        case "screen":
            guard authority.authorize(token: message["token"] as? String ?? "") else {
                return ["error": "unauthorized"]
            }
            let id = message["sessionId"] as? String ?? ""
            let since = UInt64(message["revision"] as? String ?? "0") ?? 0
            return onMain { $0.screenPayload(sessionID: id, since: since) }
        case "revoke":
            if authority.authorize(token: message["token"] as? String ?? "") {
                authority.revoke()
                control.invalidate()
            }
            return ["ok": true]
        case "control":
            guard authority.authorize(token: message["token"] as? String ?? "") else {
                return ["error": "unauthorized"]
            }
            if message["release"] as? Bool == true {
                control.release()
                return ["status": "readonly"]
            }
            if message["heartbeat"] as? Bool == true {
                let ok = control.heartbeat(leaseId: message["leaseId"] as? String ?? "")
                return ["ok": ok, "status": ok ? "controlling" : "readonly"]
            }
            if message["status"] as? Bool == true {
                return control.snapshot()
            }
            let sessionId = message["sessionId"] as? String ?? ""
            return onMain { $0.controlPayload(sessionID: sessionId) }
        case "input":
            guard authority.authorize(token: message["token"] as? String ?? "") else {
                return ["error": "unauthorized"]
            }
            return dispatchInputIPC(
                requestId: message["requestId"] as? String ?? "",
                leaseId: message["leaseId"] as? String ?? "",
                sessionId: message["sessionId"] as? String ?? "",
                kind: message["kind"] as? String ?? "text",
                text: message["text"] as? String ?? "",
                key: message["key"] as? String ?? "",
                modifiers: UInt32(message["modifiers"] as? Int ?? 0),
                enter: message["enter"] as? Bool ?? false
            )
        case "input-status":
            guard authority.authorize(token: message["token"] as? String ?? "") else {
                return ["error": "unauthorized"]
            }
            let requestId = message["requestId"] as? String ?? ""
            return control.lookup(requestId: requestId)?.json()
                ?? ["requestId": requestId, "status": "unknown", "reason": "missing"]
        default:
            return ["error": "rejected"]
        }
    }

    private func dispatchInputIPC(
        requestId: String,
        leaseId: String,
        sessionId: String,
        kind: String,
        text: String,
        key: String,
        modifiers: UInt32,
        enter: Bool
    ) -> [String: Any] {
        let box = IPCDataBox()
        let finished = DispatchSemaphore(value: 0)
        Task { @MainActor in
            guard let owner = self.owner else {
                box.data = (try? remoteJSON(["status": "rejected", "reason": "missing"])) ?? Data()
                finished.signal()
                return
            }
            owner.startInput([
                "requestId": requestId,
                "leaseId": leaseId,
                "sessionId": sessionId,
                "kind": kind,
                "text": text,
                "key": key,
                "modifiers": Int(modifiers),
                "enter": enter
            ]) { payload in
                box.data = (try? remoteJSON(payload)) ?? Data()
                finished.signal()
            }
        }
        if finished.wait(timeout: .now() + 2) == .timedOut {
            if control.abandon(requestId: requestId) {
                if box.data.isEmpty {
                    return ["requestId": requestId, "status": "unknown", "reason": "timeout"]
                }
            } else if finished.wait(timeout: .now() + 8) == .timedOut {
                return ["requestId": requestId, "status": "unknown", "reason": "timeout"]
            }
        }
        return (try? remoteObject(box.data)) ?? ["requestId": requestId, "status": "unknown", "reason": "timeout"]
    }

    private func onMain(_ body: @escaping @MainActor (RemoteService) -> [String: Any]) -> [String: Any] {
        let box = IPCDataBox()
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            if let owner = self.owner {
                box.data = (try? remoteJSON(body(owner))) ?? Data()
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
        return (try? remoteObject(box.data)) ?? ["error": "missing"]
    }
}

private final class IPCDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    var data: Data {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private final class TunnelAddressReader: @unchecked Sendable {
    private let lock = NSLock()
    private var tail = Data()
    private var found = false

    func consume(_ chunk: Data) -> String? {
        lock.withLock {
            guard !found else { return nil }
            // Scan bounded slices before dropping bytes, including split addresses.
            for offset in stride(from: 0, to: chunk.count, by: 4096) {
                tail.append(chunk.subdata(in: offset..<min(offset + 4096, chunk.count)))
                let text = String(decoding: tail, as: UTF8.self)
                if let match = text.range(of: "https://[a-z0-9-]+\\.trycloudflare\\.com", options: .regularExpression) {
                    found = true
                    tail = Data()
                    return String(text[match])
                }
                tail = Data(tail.suffix(256))
            }
            return nil
        }
    }
}

private func writeJSON(_ fd: Int32, _ object: [String: Any]) throws {
    try encodeIPC(object).withUnsafeBytes { raw in
        var sent = 0
        while sent < raw.count {
            let n = Darwin.write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
            if n <= 0 { throw RemoteError.rejected }
            sent += n
        }
    }
}

private func readJSON(_ fd: Int32) throws -> [String: Any] {
    var header = [UInt8](repeating: 0, count: 4)
    var received = 0
    while received < header.count {
        let n = header.withUnsafeMutableBytes { raw in
            Darwin.read(fd, raw.baseAddress!.advanced(by: received), raw.count - received)
        }
        guard n > 0 else { throw RemoteError.rejected }
        received += n
    }
    let length = Data(header).withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self).bigEndian) }
    guard length > 0, length <= RemoteLimits.ipcBytes else { throw RemoteError.limited }
    var payload = Data()
    var buffer = [UInt8](repeating: 0, count: min(length, 4096))
    while payload.count < length {
        let n = Darwin.read(fd, &buffer, min(buffer.count, length - payload.count))
        if n <= 0 { throw RemoteError.rejected }
        payload.append(contentsOf: buffer[0..<n])
    }
    return try remoteObject(payload)
}

private func makeQR(_ text: String) -> NSImage? {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(Data(text.utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let image = filter.outputImage else { return nil }
    let scaled = image.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
    let rep = NSCIImageRep(ciImage: scaled)
    let result = NSImage(size: rep.size)
    result.addRepresentation(rep)
    return result
}
