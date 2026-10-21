import AIETerminalCore
import AppKit
import Combine
import Darwin

@main
enum AppMain {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let arguments = CommandLine.arguments
        if arguments.contains("--headless-language") {
            HeadlessLanguage.run(arguments: arguments)
            return
        }

        let identity = AppIdentity(flavor: AppFlavor.matching(Bundle.main.bundleIdentifier))
        let workspace = workspaceURL(from: arguments)
        let app = NSApplication.shared
        let delegate = AppDelegate(identity: identity, workspace: workspace)
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        NSWindow.allowsAutomaticWindowTabbing = false
        app.run()
    }

    static func workspaceURL(from arguments: [String]) -> URL {
        if let index = arguments.firstIndex(of: "--workspace"), arguments.indices.contains(index + 1) {
            return URL(fileURLWithPath: arguments[index + 1])
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let identity: AppIdentity
    let workspace: URL
    var coordinator: SessionCoordinator?
    var windowController: MainWindowController?
    private var appearanceWindow: AppearanceWindowController?
    private var remotePanel: RemotePanelController?
    private var languageSink: AnyCancellable?

    init(identity: AppIdentity, workspace: URL) {
        self.identity = identity
        self.workspace = workspace
        super.init()
        languageSink = L10n.shared.$language.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.buildMenu()
        }
    }

    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.coordinator?.markUntrustedIfWorking()
            }
        }
        do {
            let coordinator = try SessionCoordinator(identity: identity)
            coordinator.remote.autoQuickTunnel = true
            self.coordinator = coordinator
            buildMenu()
            showMainWindow()
        } catch {
            let alert = NSAlert()
            alert.messageText = L10n.text("应用未能启动。")
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: L10n.text("关闭"))
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.quitProcesses()
    }

    private var terminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        coordinator?.quitProcesses()
        Task { @MainActor in
            await coordinator?.waitForCleanup()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    @objc func newSession(_ sender: Any?) {
        if windowController?.window == nil || windowController?.window?.isVisible == false {
            showMainWindow()
        } else {
            coordinator?.createSession()
        }
    }

    @objc func closeSession(_ sender: Any?) {
        coordinator?.closeSelectedSession()
    }

    @objc func showRemote(_ sender: Any?) {
        guard let coordinator else { return }
        if remotePanel == nil { remotePanel = RemotePanelController(service: coordinator.remote) }
        remotePanel?.refresh()
        remotePanel?.showWindow(nil)
        remotePanel?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func showSettings(_ sender: Any?) {
        guard let coordinator else { return }
        if appearanceWindow == nil { appearanceWindow = AppearanceWindowController(store: coordinator.appearance) }
        appearanceWindow?.showWindow(nil)
        appearanceWindow?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func increaseFont(_ sender: Any?) { coordinator?.appearance.update { $0.fontSize += 1 } }
    @objc func decreaseFont(_ sender: Any?) { coordinator?.appearance.update { $0.fontSize -= 1 } }
    @objc func resetFont(_ sender: Any?) { coordinator?.appearance.update { $0.fontSize = 13 } }

    private func showMainWindow() {
        guard let coordinator else { return }
        if windowController?.window == nil {
            windowController = MainWindowController(coordinator: coordinator, workspace: workspace)
        } else if coordinator.sessions.isEmpty {
            coordinator.bootstrap(workspace: workspace)
            windowController?.rebuildStack()
        }
        if windowController?.window?.isVisible == false { windowController?.maximizeForOpening() }
        windowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showAbout(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = L10n.text("关于 %@", identity.flavor.displayName)
        alert.informativeText = L10n.text("版本 %@", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")
        alert.addButton(withTitle: L10n.text("关闭"))
        alert.runModal()
    }

    func buildMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let name = identity.flavor.displayName
        let appMenu = NSMenu(title: name)
        appMenu.addItem(withTitle: L10n.text("关于 %@", name), action: #selector(showAbout(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: L10n.text("设置…"), action: #selector(showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(withTitle: L10n.text("远程…"), action: #selector(showRemote(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: L10n.text("退出 %@", name), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: L10n.text("文件"))
        fileMenu.addItem(withTitle: L10n.text("新建终端"), action: #selector(newSession(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: L10n.text("关闭终端"), action: #selector(closeSession(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: L10n.text("编辑"))
        editMenu.addItem(withTitle: L10n.text("复制"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L10n.text("粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L10n.text("全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: L10n.text("显示"))
        viewMenu.addItem(withTitle: L10n.text("增大字号"), action: #selector(increaseFont(_:)), keyEquivalent: "+")
        let equal = viewMenu.addItem(withTitle: L10n.text("增大字号"), action: #selector(increaseFont(_:)), keyEquivalent: "=")
        equal.isHidden = true
        equal.allowsKeyEquivalentWhenHidden = true
        viewMenu.addItem(withTitle: L10n.text("减小字号"), action: #selector(decreaseFont(_:)), keyEquivalent: "-")
        viewMenu.addItem(withTitle: L10n.text("默认字号"), action: #selector(resetFont(_:)), keyEquivalent: "0")
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: L10n.text("窗口"))
        windowMenu.addItem(withTitle: L10n.text("最小化"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = mainMenu
    }
}
