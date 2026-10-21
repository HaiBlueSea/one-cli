import AIETerminalCore
import AppKit
import Combine
import SwiftUI

private final class SidebarHostingView: NSHostingView<SessionSidebar> {
    override var acceptsFirstResponder: Bool { false }
}

@MainActor
final class MainWindowController: NSWindowController {
    let coordinator: SessionCoordinator
    private let stack = NSView()
    private let split: NSSplitView
    private let sidebarHost: SidebarHostingView
    private let sidebarButton = NSButton()
    private let projectLabel = NSTextField(labelWithString: "")
    private let branchLabel = NSTextField(labelWithString: "")
    private let sessionLabel = NSTextField(labelWithString: "")
    private var adjustingSidebar = false
    private let headerAccessory = NSTitlebarAccessoryViewController()

    init(coordinator: SessionCoordinator, workspace: URL) {
        self.coordinator = coordinator
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        let sidebarHost = SidebarHostingView(rootView: SessionSidebar(coordinator: coordinator))
        sidebarHost.appearance = NSAppearance(named: .darkAqua)
        self.sidebarHost = sidebarHost
        self.split = split
        stack.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(sidebarHost)
        split.addArrangedSubview(stack)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        sidebarHost.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sidebarHost.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: coordinator.windowWidth, height: coordinator.windowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = coordinator.identity.flavor.displayName
        window.contentView = split
        window.setContentSize(NSSize(width: coordinator.windowWidth, height: coordinator.windowHeight))
        super.init(window: window)
        configureToolbar()
        maximizeForOpening()
        window.delegate = self
        split.delegate = self
        split.setPosition(CGFloat(coordinator.sidebarWidth), ofDividerAt: 0)
        coordinator.bootstrap(workspace: workspace)
        rebuildStack()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.split.setPosition(CGFloat(self.coordinator.sidebarWidth), ofDividerAt: 0)
            self.coordinator.finishApplyingWindowLayout()
            self.recordWindowLayout()
            self.focusSelectedTerminal()
        }
        // @Published emits before mutation; deliver on the next main-queue
        // turn so every add/remove path sees the final session collection.
        coordinator.$sessions.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.rebuildStack()
        }.store(in: &sinks)
        coordinator.$sidebarEpoch
            .dropFirst()
            .sink { [weak self] _ in
                self?.reloadSidebar()
            }
            .store(in: &sinks)
        coordinator.appearance.$value.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.applyAppearance()
        }.store(in: &sinks)
        coordinator.$selectedID.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.updateToolbarInformation()
        }.store(in: &sinks)
        L10n.shared.$language.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.updateToolbarInformation()
            self?.applyTerminalLanguage()
        }.store(in: &sinks)
        applyAppearance()
        updateToolbarInformation()
    }

    private var sinks = Set<AnyCancellable>()

    private func applyTerminalLanguage() {
        for session in coordinator.sessions { session.host.view.localizeUI = L10n.terminalText }
    }

    private func applyAppearance() {
        applyTerminalLanguage()
        let store = coordinator.appearance
        NSApp.appearance = NSAppearance(named: store.value.theme.isLight ? .aqua : .darkAqua)
        sidebarHost.appearance = NSApp.appearance
        for session in coordinator.sessions { store.apply(to: session.host.view) }
        window?.backgroundColor = store.value.theme.background
        projectLabel.textColor = store.value.theme.foreground
        branchLabel.textColor = store.value.theme.foreground.withAlphaComponent(0.65)
        sessionLabel.textColor = branchLabel.textColor
        sidebarButton.contentTintColor = branchLabel.textColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func reloadSidebar() {
        sidebarHost.rootView = SessionSidebar(coordinator: coordinator)
        updateToolbarInformation()
        focusSelectedTerminal()
    }

    func rebuildStack() {
        let existing = Set(stack.subviews.map { ObjectIdentifier($0) })
        for session in coordinator.sessions {
            if !existing.contains(ObjectIdentifier(session.host.view)) {
                session.host.view.translatesAutoresizingMaskIntoConstraints = true
                session.host.view.autoresizingMask = [.width, .height]
                session.host.view.frame = stack.bounds
                stack.addSubview(session.host.view)
            }
        }
        let live = Set(coordinator.sessions.map { ObjectIdentifier($0.host.view) })
        for view in stack.subviews where !live.contains(ObjectIdentifier(view)) {
            view.removeFromSuperview()
        }
        coordinator.applyVisibility()
        updateToolbarInformation()
        focusSelectedTerminal()
    }

    func maximizeForOpening() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        window.setFrame(screen.visibleFrame, display: false)
    }

    private func configureToolbar() {
        guard let window else { return }
        sidebarButton.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: L10n.text("折叠侧栏"))
        sidebarButton.isBordered = false
        sidebarButton.refusesFirstResponder = true
        sidebarButton.target = self
        sidebarButton.action = #selector(toggleSidebar(_:))
        sidebarButton.widthAnchor.constraint(equalToConstant: 30).isActive = true
        sidebarButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        projectLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        for label in [projectLabel, branchLabel, sessionLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.widthAnchor.constraint(lessThanOrEqualToConstant: label === projectLabel ? 280 : 180).isActive = true
        }
        let toolbar = NSToolbar(identifier: "AIEMainToolbar")
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        let information = NSStackView(views: [sidebarButton, projectLabel, branchLabel, sessionLabel])
        information.orientation = .horizontal
        information.alignment = .centerY
        information.spacing = 20
        information.detachesHiddenViews = true
        information.frame = NSRect(x: 0, y: 0, width: 400, height: 24)
        headerAccessory.identifier = NSUserInterfaceItemIdentifier("AIESessionInformation")
        headerAccessory.layoutAttribute = .left
        headerAccessory.view = information
        window.addTitlebarAccessoryViewController(headerAccessory)
    }

    private func updateToolbarInformation() {
        let selected = coordinator.sessions.first { $0.id == coordinator.selectedID }
        projectLabel.stringValue = selected.map { URL(fileURLWithPath: $0.cwd).lastPathComponent } ?? coordinator.identity.flavor.displayName
        projectLabel.toolTip = selected?.cwd
        branchLabel.stringValue = selected.flatMap { coordinator.gitBranch(for: $0.cwd) } ?? ""
        branchLabel.isHidden = branchLabel.stringValue.isEmpty
        branchLabel.toolTip = branchLabel.stringValue
        sessionLabel.stringValue = selected.map { $0.title == "Terminal" ? L10n.text("命令行") : $0.title } ?? L10n.text("无会话")
        sessionLabel.toolTip = sessionLabel.stringValue
        let action = L10n.text(sidebarHost.isHidden ? "展开侧栏" : "折叠侧栏")
        sidebarButton.toolTip = action
        sidebarButton.setAccessibilityLabel(action)
        let information = headerAccessory.view
        information.layoutSubtreeIfNeeded()
        let titlebarHeight = window.map { $0.frame.height - $0.contentLayoutRect.height } ?? 35
        information.setFrameSize(NSSize(width: min(information.fittingSize.width, max(120, (window?.frame.width ?? 480) - 140)), height: max(24, titlebarHeight)))
    }

    @objc private func toggleSidebar(_ sender: Any?) {
        let width = coordinator.sidebarWidth
        adjustingSidebar = true
        if sidebarHost.isHidden {
            sidebarHost.isHidden = false
            split.insertArrangedSubview(sidebarHost, at: 0)
            split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        } else {
            sidebarHost.isHidden = true
            // A hidden arranged view can leave its divider drawn over the
            // expanded terminal. A single-pane split has no divider to draw.
            sidebarHost.removeFromSuperview()
        }
        split.adjustSubviews()
        if !sidebarHost.isHidden { split.setPosition(CGFloat(width), ofDividerAt: 0) }
        split.needsDisplay = true
        adjustingSidebar = false
        recordWindowLayout()
        updateToolbarInformation()
        focusSelectedTerminal()
    }

    func shutdownWindow() {
        coordinator.closeWindowProcesses()
        rebuildStack()
    }

    private func focusSelectedTerminal() {
        guard let selected = coordinator.sessions.first(where: { $0.id == coordinator.selectedID }) else { return }
        window?.makeFirstResponder(selected.host.view)
    }
}

extension MainWindowController: NSWindowDelegate, NSSplitViewDelegate {
    func windowWillClose(_ notification: Notification) {
        recordWindowLayout()
        coordinator.persist(immediate: true)
        shutdownWindow()
    }

    func windowDidResize(_ notification: Notification) {
        updateToolbarInformation()
        recordWindowLayout()
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        recordWindowLayout()
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        160
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(160, splitView.bounds.width - 360)
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        false
    }

    func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool {
        sidebarHost.isHidden
    }

    private func recordWindowLayout() {
        guard let window, !adjustingSidebar else { return }
        coordinator.updateWindowLayout(
            width: Double(window.frame.width),
            height: Double(window.frame.height),
            sidebarWidth: sidebarHost.isHidden ? coordinator.sidebarWidth : Double(sidebarHost.frame.width)
        )
    }
}
