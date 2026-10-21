import AIETerminalCore
import AppKit
import SwiftTerm

@MainActor
final class TerminalHost: NSObject, LocalProcessTerminalViewDelegate {
    let sessionID: String
    let ptyGeneration: UInt64
    let view: AppTerminalView
    let identity: AppIdentity
    let startDirectory: String
    private(set) var cleaned = false
    private var startTask: Task<Void, Never>?
    var onTerminated: ((Int32?) -> Void)?
    var onTitleChanged: ((String) -> Void)?

    init(
        identity: AppIdentity,
        startDirectory: String,
        sessionID: String = UUID().uuidString,
        ptyGeneration: UInt64 = 1,
        options: TerminalOptions = TerminalOptions.default
    ) {
        self.identity = identity
        self.startDirectory = startDirectory
        self.sessionID = sessionID
        self.ptyGeneration = ptyGeneration
        self.view = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480), font: .monospacedSystemFont(ofSize: 12, weight: .regular), options: options)
        super.init()
        view.linkDirectory = startDirectory
        view.processDelegate = self
    }

    func start(environment extras: [String: String]) {
        startTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let environment = await LoginEnvironment.cachedSnapshot()
            guard let self, !self.cleaned, !Task.isCancelled else { return }
            self.startProcess(environment: environment, extras: extras)
            self.startTask = nil
        }
    }

    private func startProcess(environment initial: [String: String], extras: [String: String]) {
        var environment = initial
        environment.merge(extras) { _, new in new }
        let preferColors = environment.removeValue(forKey: "AIE_COLOR_OUTPUT") != "0"
        environment = Self.colorEnvironment(environment, enabled: preferColors)
        environment["LANG"] = "en_US.UTF-8"
        environment["LC_ALL"] = "en_US.UTF-8"
        let zdot = (try? RuntimePaths.installZshDotDir(from: ResourceLocator.zshDotDir(), flavor: identity.flavor))
            ?? ResourceLocator.zshDotDir()
        environment["ZDOTDIR"] = zdot.path
        environment["AIE_BOOTSTRAP_ZDOTDIR"] = zdot.path
        if environment["AIE_USER_ZDOTDIR"] == nil {
            if let existing = ProcessInfo.processInfo.environment["ZDOTDIR"] {
                environment["AIE_USER_ZDOTDIR"] = existing
            }
        }
        if let wrap = environment["AIE_WRAPPER_BIN"] {
            let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            let parts = path.split(separator: ":").map(String.init)
            if !parts.contains(wrap) {
                environment["PATH"] = wrap + ":" + path
            }
        }
        view.startProcess(
            executable: "/bin/zsh",
            args: ["-il"],
            environment: LoginEnvironment.processArray(environment),
            execName: "-zsh",
            currentDirectory: startDirectory
        )
    }

    func sendText(_ text: String) {
        view.process.send(data: Array(text.utf8)[...])
    }

    func sendBytes(_ bytes: [UInt8], completion: @escaping @Sendable (Result<Int, LocalProcessError>) -> Void) {
        view.process.send(data: bytes[...], completion: completion)
    }

    func simulateLocalTyping(_ text: String) {
        _ = view.sendLocalHostText(text)
    }

    static func colorEnvironment(_ initial: [String: String], enabled: Bool) -> [String: String] {
        var environment = initial
        // Advertise this emulator's capabilities, not the launching terminal's.
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        if enabled {
            environment["CLICOLOR"] = "1"
            environment.removeValue(forKey: "NO_COLOR")
        }
        return environment
    }

    @discardableResult
    func closeAndReap(exclude: Set<pid_t> = []) async -> ReaperResult? {
        guard !cleaned else { return nil }
        cleaned = true
        let pendingStart = startTask
        pendingStart?.cancel()
        startTask = nil
        // A shared environment probe may already own a child process. Wait
        // for its bounded completion/cleanup before App termination can finish.
        await pendingStart?.value
        let pid = view.process.shellPid
        let result: ReaperResult? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = try? ProcessReaper.reap(roots: pid > 1 ? [pid] : [], exclude: exclude.union([ProcessInfo.processInfo.processIdentifier]))
                continuation.resume(returning: result)
            }
        }
        view.terminate()
        return result
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        source.window?.title = "\(identity.flavor.displayName) — \(title)"
        onTitleChanged?(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // OSC 7 is informational only; directory grouping uses top-level Shell events.
        NotificationCenter.default.post(name: .aieOSC7, object: directory)
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        onTerminated?(exitCode)
    }
}

extension Notification.Name {
    static let aieOSC7 = Notification.Name("aie.osc7")
}
