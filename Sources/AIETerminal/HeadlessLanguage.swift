import AIETerminalCore
import AppKit
import Darwin
import Foundation

/// Uses a task-owned HOME and verification identity; never opens the installed application.
@MainActor
enum HeadlessLanguage {
    private static var coordinatorForCleanup: SessionCoordinator?
    static func run(arguments: [String]) {
        guard let index = arguments.firstIndex(of: "--workspace"), arguments.indices.contains(index + 1) else { exit(2) }
        let root = URL(fileURLWithPath: arguments[index + 1])
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        NSWindow.allowsAutomaticWindowTabbing = false
        Task { @MainActor in
            do { try await execute(root: root) }
            catch {
                coordinatorForCleanup?.remote.disable()
                coordinatorForCleanup?.quitProcesses()
                await coordinatorForCleanup?.waitForCleanup()
                fputs("Language checks failed: \(error)\n", stderr)
                exit(1)
            }
        }
        app.run()
    }

    private static func execute(root: URL) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var checks: [String: Bool] = [:]
        let legacy = try JSONDecoder().decode(TerminalAppearance.self, from: Data(#"{"fontSize":17,"theme":"Nord"}"#.utf8))
        checks["legacy-defaults-to-chinese"] = legacy.language == .chinese && legacy.fontSize == 17 && legacy.theme == .nord
        let unknown = try JSONDecoder().decode(TerminalAppearance.self, from: Data(#"{"language":"fr"}"#.utf8))
        checks["unsupported-language-falls-back"] = unknown.language == .chinese
        let malformed = try JSONDecoder().decode(TerminalAppearance.self, from: Data(#"{"language":42,"fontSize":17}"#.utf8))
        checks["malformed-language-keeps-other-settings"] = malformed.language == .chinese && malformed.fontSize == 17
        let identity = AppIdentity(flavor: .verification)
        let coordinator = try SessionCoordinator(identity: identity, snapshotStore: SnapshotStore(url: root.appendingPathComponent("layout.json")))
        coordinatorForCleanup = coordinator
        let delegate = AppDelegate(identity: identity, workspace: root)
        delegate.coordinator = coordinator
        let main = MainWindowController(coordinator: coordinator, workspace: root)
        delegate.windowController = main
        let settings = AppearanceWindowController(store: coordinator.appearance)
        let remote = RemotePanelController(service: coordinator.remote)
        defer { coordinator.quitProcesses(); coordinator.remote.disable() }
        let session = coordinator.sessions[0]
        for _ in 0..<150 {
            if session.host.view.process.shellPid > 1 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let pid = session.host.view.process.shellPid
        checks["isolated-shell-started"] = pid > 1
        let generation = session.host.ptyGeneration
        let id = session.id
        let findItem = NSMenuItem()
        findItem.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        session.host.view.performFindPanelAction(findItem)
        delegate.buildMenu()
        let menuKeys = ["n", "w", "c", "v", "a", "+", "=", "-", "0", "m", "q", ","]
        var originalActions: [String: String] = [:]
        for language in [AppLanguage.chinese, .english, .chinese] {
            coordinator.appearance.update { $0.language = language }
            try await Task.sleep(for: .milliseconds(350))
            session.agentState = "working"
            let suffix = language.rawValue
            checks[suffix + "-window-titles"] = settings.window?.title == language.text("设置") && remote.window?.title == language.text("远程")
            checks[suffix + "-session-status"] = session.subtitle.hasPrefix(language.text("工作中"))
            checks[suffix + "-session-name"] = session.displayName == language.text("终端")
            checks[suffix + "-live-terminal-controls"] = session.host.view.localizeUI("Find") == language.text("查找")
            let items = NSApp.mainMenu!.items.flatMap { $0.submenu?.items ?? [] }
            var actions: [String: String] = [:]
            for key in menuKeys {
                if let item = items.first(where: { $0.keyEquivalent == key }), let action = item.action { actions[key] = NSStringFromSelector(action) }
            }
            if originalActions.isEmpty { originalActions = actions }
            checks[suffix + "-shortcuts-preserved"] = actions.count == menuKeys.count && actions == originalActions
            checks[suffix + "-menu-titles"] = items.contains { $0.title == language.text("新建终端") } && items.contains { $0.title == language.text("复制") }
            checks[suffix + "-preferences-persisted"] = try JSONDecoder().decode(TerminalAppearance.self, from: Data(contentsOf: coordinator.appearance.url)).language == language
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            checks[suffix + "-existing-find-bar"] = descendants(session.host.view).compactMap { $0 as? NSSearchField }.contains {
                $0.placeholderString == language.text("查找")
            }
            let remoteButtons = descendants(remote.window!.contentView!).compactMap { $0 as? NSButton }
            checks[suffix + "-remote-button-labels"] = ["复制链接", "在本机打开", "开启远程", "确认配对", "拒绝", "撤销"].allSatisfy { key in
                remoteButtons.contains { $0.title == language.text(key) }
            }
            checks[suffix + "-remote-button-widths"] = remoteButtons.allSatisfy { button in
                (button.title as NSString).size(withAttributes: [.font: button.font ?? NSFont.systemFont(ofSize: 13)]).width + 20 <= button.bounds.width
            }
            for (name, controller) in [("settings", settings as NSWindowController), ("remote", remote), ("main", main)] {
                if let view = controller.window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.layoutSubtreeIfNeeded()
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: root.appendingPathComponent("\(name)-\(suffix).png")) }
                }
            }
        }
        checks["switch-keeps-shell-and-selection"] = session.host.view.process.shellPid == pid && session.host.ptyGeneration == generation && coordinator.selectedID == id && coordinator.sessions.count == 1
        coordinator.appearance.update { $0.language = .english }
        let reloaded = TerminalAppearanceStore(url: coordinator.appearance.url)
        checks["relaunch-keeps-language"] = reloaded.value.language == .english && L10n.shared.language == .english
        coordinator.remote.enable()
        var base = URLComponents()
        base.scheme = "http"; base.host = "127.0.0.1"; base.port = Int(identity.flavor.remotePort)
        var ready = false
        for _ in 0..<50 {
            if let (_, reply) = try? await URLSession.shared.data(from: base.url!.appendingPathComponent("health")), (reply as? HTTPURLResponse)?.statusCode == 200 { ready = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        checks["remote-helper-started"] = ready
        if ready {
            let fragment = coordinator.remote.url.split(separator: "#").last.map(String.init) ?? ""
            let challenge = String(fragment.dropFirst(2))
            let origin = "http://127.0.0.1:\(identity.flavor.remotePort)"
            var request = URLRequest(url: base.url!.appendingPathComponent("pair"))
            request.httpMethod = "POST"
            request.setValue(origin, forHTTPHeaderField: "Origin")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["challenge": challenge])
            let (pending, _) = try await URLSession.shared.data(for: request)
            checks["pairing-contains-language"] = (try JSONSerialization.jsonObject(with: pending) as? [String: Any])?["language"] as? String == "en"
            coordinator.remote.confirm()
            _ = try await URLSession.shared.data(for: request)
            for language in [AppLanguage.english, .chinese] {
                coordinator.appearance.update { $0.language = language }
                let (html, _) = try await URLSession.shared.data(from: base.url!)
                checks[language.rawValue + "-real-http-language"] = String(decoding: html, as: UTF8.self).contains("<html lang=\"\(language.rawValue)\">")
                let (sessions, _) = try await URLSession.shared.data(from: base.url!.appendingPathComponent("api/sessions"))
                let payload = try JSONSerialization.jsonObject(with: sessions) as? [String: Any]
                checks[language.rawValue + "-real-sessions-language"] = payload?["language"] as? String == language.rawValue && payload?["sessions"] != nil
            }
        }
        coordinator.remote.disable()
        coordinator.quitProcesses()
        await coordinator.waitForCleanup()
        let report: [String: Any] = ["checks": checks, "ok": checks.values.allSatisfy { $0 }]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("native-language.json"))
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
        exit(checks.values.allSatisfy { $0 } ? 0 : 1)
    }
}
