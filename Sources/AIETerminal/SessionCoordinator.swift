import AIETerminalCore
import AIETerminalRemoteCore
import AppKit
import Combine
import Foundation

@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    let id: String
    let host: TerminalHost
    @Published var cwd: String
    @Published var title = "Terminal"
    @Published var agentState = "none"
    @Published var launchID: String?
    @Published var agentType: String?
    var activeTurnIDs: Set<String> = []
    var stateExpiresAt: Date?
    let createdAt = Date()
    @Published var touchedAt = Date()
    var didBecomeReady = false
    var nativeBridgeID: String?
    var nativeBridgeStarted: UInt64 = 0
    var nativeBridgeSequence: UInt64 = 0
    var nativeBridgeDead = false
    var nativeThreadID: String?
    var nativeCodexHome: String?
    var nativeCodexTitle: String?

    init(host: TerminalHost, cwd: String) {
        self.id = host.sessionID
        self.host = host
        self.cwd = cwd
    }

    var displayName: String {
        title
    }

    var subtitle: String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: touchedAt)
        let clock = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        switch agentState {
        case "unknown":
            return "未知状态 · \(clock)"
        case "idle":
            return "等待中 · \(clock)"
        case "working":
            return "工作中 · \(clock)"
        case "needsInput":
            return "等待输入 · \(clock)"
        default:
            return "新会话 · \(clock)"
        }
    }

    func touch() {
        touchedAt = Date()
    }

    var activity: AgentActivity {
        get {
            AgentActivity(state: agentState, activeTurnIDs: activeTurnIDs, expiresAt: stateExpiresAt)
        }
        set {
            agentState = newValue.state
            activeTurnIDs = newValue.activeTurnIDs
            stateExpiresAt = newValue.expiresAt
        }
    }
}

struct LayoutSlot: Sendable, Equatable {
    var id: String
    var cwd: String
}

@MainActor
final class SessionCoordinator: ObservableObject {
    @Published var sessions: [TerminalSession] = []
    @Published var selectedID: String?
    @Published var note = ""
    let remote: RemoteService

    let identity: AppIdentity
    let server: EventServer
    let launcherMap: LauncherMap
    let helperPath: String
    private let codexWrapperDirectory: String
    let socketPath: String
    let snapshotStore: SnapshotStore
    let appearance: TerminalAppearanceStore
    @Published var collapsedGroups: Set<String> = []
    @Published private(set) var sidebarEpoch: UInt64 = 0
    @Published private(set) var windowWidth: Double = 1100
    @Published private(set) var windowHeight: Double = 680
    @Published private(set) var sidebarWidth: Double = 200
    private var branchCache: [String: String] = [:]
    private var daemonObservers: [String: (serviceID: String, launchID: String, observer: CodexDaemonObserver)] = [:]
    private var titleObservers: [String: (id: UUID, prefix: String, launchID: String, observer: CodexTitleObserver)] = [:]
    private var nativeBridgeWatches: [String: any DispatchSourceProcess] = [:]
    private var claudeWatches: [String: ClaudeSessionWatch] = [:]
    private let daemonEventSlots = DispatchSemaphore(value: 128)
    private var nextPTYGeneration: UInt64 = 1
    var activeDaemonObserverCount: Int { daemonObservers.count + titleObservers.count }
    var daemonObserverFailures: [String: String] {
        daemonObservers.compactMapValues { $0.observer.failureReason }
            .merging(titleObservers.compactMapValues { $0.observer.failureReason }) { _, new in new }
    }
    private(set) var frozenSlots: [LayoutSlot] = []
    private var frozenSelectedID: String?
    private var didLoadSnapshot = false
    private var freezeWrites = false
    private var layoutRevision: UInt64 = 0
    private var persistDirty = false
    private var persistWorkItem: DispatchWorkItem?
    private var expiryTask: Task<Void, Never>?
    private var applyingWindowLayout = true
    private let homePath = FileManager.default.homeDirectoryForCurrentUser.path
    private var selectedCWD: String {
        sessions.first(where: { $0.id == selectedID })?.cwd ?? homePath
    }

    init(identity: AppIdentity, snapshotStore: SnapshotStore? = nil) throws {
        self.identity = identity
        appearance = TerminalAppearanceStore(url: try RuntimePaths.supportDirectory(flavor: identity.flavor).appendingPathComponent("appearance.json"))
        launcherMap = (try? LauncherMap.load(from: ResourceLocator.launchersURL()))
            ?? LauncherMap(launchers: [
                "codex": "codex", "codex1": "codex", "codex2": "codex", "kimi": "kimi",
                "claude": "claude", "claude1": "claude", "cursor": "cursor", "agent": "cursor", "cursor-agent": "cursor"
            ])
        let socketURL = try RuntimePaths.socketURL(flavor: identity.flavor, appRunID: identity.appRunID)
        socketPath = socketURL.path
        helperPath = ((try? RuntimePaths.installHelper(from: ResourceLocator.helperURL(), flavor: identity.flavor))
            ?? ResourceLocator.helperURL()).path
        codexWrapperDirectory = try RuntimePaths.installCodexWrapper(from: ResourceLocator.codexWrapperURL(), flavor: identity.flavor).deletingLastPathComponent().path
        self.snapshotStore = try snapshotStore ?? SnapshotStore(flavor: identity.flavor)
        server = EventServer(identity: identity, socketPath: socketPath)
        remote = RemoteService(identity: identity, coordinator: nil)
        remote.bind(coordinator: self)
        if !launcherMap.invalidMappings.isEmpty {
            note = "launchers.json 含未知类型：\(launcherMap.invalidMappings.joined(separator: ", "))。"
        }
        switch self.snapshotStore.load() {
        case .missing:
            break
        case .loaded(let snapshot):
            applyLoadedSnapshot(snapshot)
        case .corrupt:
            freezeWrites = true
            note = "布局文件损坏，已保留副本并暂停布局保存；请恢复文件后重启。"
        case .unsupportedSchema(let version):
            freezeWrites = true
            note = "布局版本 \(version) 不受支持，未覆盖原文件。"
        }
        let eventSlots = DispatchSemaphore(value: 128)
        try server.start { [weak self] envelope in
            eventSlots.wait()
            Task { @MainActor in
                defer { eventSlots.signal() }
                self?.handle(envelope)
            }
        }
        let helper = helperPath
        DispatchQueue.global(qos: .utility).async {
            NativeCLIHooks.installInstalledHomes(helperPath: helper)
        }
    }

    private func applyLoadedSnapshot(_ snapshot: LayoutSnapshot) {
        let sanitized = snapshot.sanitized(home: homePath)
        didLoadSnapshot = true
        layoutRevision = sanitized.0.writeRevision
        frozenSlots = sanitized.0.slots.map { LayoutSlot(id: $0.id, cwd: $0.cwd) }
        frozenSelectedID = sanitized.0.selectedID
        collapsedGroups = Set(sanitized.0.collapsedGroups)
        windowWidth = sanitized.0.windowWidth
        windowHeight = sanitized.0.windowHeight
        sidebarWidth = sanitized.0.sidebarWidth == 300 ? 200 : sanitized.0.sidebarWidth
        if sanitized.fellBack {
            note = "有目录不可访问，已回退到 Home。"
        }
    }

    func bootstrap(workspace: URL) {
        if frozenSlots.isEmpty {
            if !didLoadSnapshot {
                _ = createSession(cwd: workspace.path)
            }
            return
        }
        restoreSlots()
    }

    func finishApplyingWindowLayout() {
        applyingWindowLayout = false
    }

    func updateWindowLayout(width: Double, height: Double, sidebarWidth: Double) {
        guard !applyingWindowLayout else { return }
        let nextWidth = LayoutPath.clamp(width, min: 480, max: 10_000, fallback: windowWidth)
        let nextHeight = LayoutPath.clamp(height, min: 320, max: 10_000, fallback: windowHeight)
        let nextSidebar = LayoutPath.clamp(sidebarWidth, min: 160, max: nextWidth - 320, fallback: self.sidebarWidth)
        if nextWidth == windowWidth, nextHeight == windowHeight, nextSidebar == self.sidebarWidth {
            return
        }
        windowWidth = nextWidth
        windowHeight = nextHeight
        self.sidebarWidth = nextSidebar
        persist()
    }

    @discardableResult
    func createSession(cwd: String? = nil, id: String? = nil, select: Bool = true, persistNow: Bool = true) -> TerminalSession {
        let resolved = LayoutPath.resolveForRestore(cwd ?? selectedCWD, home: homePath)
        if resolved.fellBack {
            note = "目录不可访问，已回退到 Home。"
        }
        let host = TerminalHost(identity: identity, startDirectory: resolved.cwd, sessionID: id ?? UUID().uuidString, ptyGeneration: nextPTYGeneration)
        nextPTYGeneration += 1
        appearance.apply(to: host.view)
        let session = TerminalSession(host: host, cwd: resolved.cwd)
        host.onTitleChanged = { [weak self, weak host] title in
            guard let self, let host, let current = self.sessions.first(where: { $0.host === host }) else { return }
            self.observeCodexTitle(title, session: current)
        }
        host.view.onLinkFailure = { [weak self] message in self?.note = message }
        host.start(environment: environment(for: host))
        host.onTerminated = { [weak self, weak host, sessionID = session.id] _ in
            Task { @MainActor in
                guard let self, let host, self.isBatchClosing != true,
                      let session = self.sessions.first(where: { $0.id == sessionID }), session.host === host else { return }
                if session.didBecomeReady {
                    self.note = "会话已退出。"
                    self.removeSession(id: sessionID, deleteSlot: true)
                } else {
                    self.note = "会话未能启动。若系统询问文稿权限，请点允许后再开这个目录。"
                }
            }
        }
        sessions.append(session)
        remote.attach(host)
        if select {
            selectedID = session.id
        }
        applyVisibility()
        if persistNow {
            persist()
        }
        return session
    }

    func select(id: String) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        selectedID = id
        applyVisibility()
        persist()
    }

    func toggleGroup(_ cwd: String) {
        if collapsedGroups.contains(cwd) {
            collapsedGroups.remove(cwd)
        } else {
            collapsedGroups.insert(cwd)
        }
        sidebarEpoch += 1
        persist()
    }

    func closeSelectedSession() {
        guard let selectedID else { return }
        closeSession(id: selectedID)
    }

    func closeSession(id: String) {
        removeSession(id: id, deleteSlot: true)
    }

    private var isBatchClosing = false
    private var cleanupTasks: [UUID: Task<Void, Never>] = [:]

    private func cleanUp(_ host: TerminalHost) {
        titleObservers.removeValue(forKey: host.sessionID)?.observer.stop()
        nativeBridgeWatches.removeValue(forKey: host.sessionID)?.cancel()
        daemonObservers.removeValue(forKey: host.sessionID)?.observer.stop()
        claudeWatches.removeValue(forKey: host.sessionID)?.stop()
        let id = UUID()
        cleanupTasks[id] = Task { [weak self] in
            let result = await host.closeAndReap()
            if result?.timedOut == true { self?.note = "部分受管进程尚未退出。" }
            self?.cleanupTasks[id] = nil
        }
    }

    func waitForCleanup() async {
        while !cleanupTasks.isEmpty {
            let tasks = Array(cleanupTasks.values)
            for task in tasks { await task.value }
        }
    }

    func closeWindowProcesses() {
        if !sessions.isEmpty {
            frozenSlots = sessions.map { LayoutSlot(id: $0.id, cwd: $0.cwd) }
            frozenSelectedID = selectedID
        }
        isBatchClosing = true
        for session in sessions {
            cleanUp(session.host)
        }
        sessions.removeAll()
        selectedID = nil
        isBatchClosing = false
        persist(immediate: true)
    }

    func quitProcesses() {
        if !sessions.isEmpty {
            frozenSlots = sessions.map { LayoutSlot(id: $0.id, cwd: $0.cwd) }
            frozenSelectedID = selectedID
        }
        persist(immediate: true)
        isBatchClosing = true
        for session in sessions {
            cleanUp(session.host)
        }
        sessions.removeAll()
        selectedID = nil
        isBatchClosing = false
        server.stop()
        remote.disable()
    }

    func remoteSessions() -> [RemoteSessionDTO] {
        sessions.map {
            RemoteSessionDTO(
                id: $0.id,
                cwd: $0.cwd,
                title: $0.title,
                state: $0.agentState,
                ptyGeneration: $0.host.ptyGeneration
            )
        }
    }

    func remoteScreen(sessionID: String, since: UInt64 = 0) -> [String: Any] {
        guard let session = sessions.first(where: { $0.id == sessionID }) else {
            return ["error": "missing"]
        }
        let snapshot = session.host.view.exportLiveScreen()
        let lines = snapshot.lines.map { row in
            row.cells.map { cell in
                if cell.width == 0 { return "" }
                return cell.text.isEmpty ? " " : cell.text
            }.joined()
        }
        var hasher = Hasher()
        hasher.combine(session.host.ptyGeneration)
        hasher.combine(snapshot.cols)
        hasher.combine(snapshot.rows)
        hasher.combine(snapshot.isAlternateScreen)
        hasher.combine(snapshot.cursor.x)
        hasher.combine(snapshot.cursor.y)
        hasher.combine(snapshot.cursor.hidden)
        for line in lines { hasher.combine(line) }
        let revision = UInt64(bitPattern: Int64(hasher.finalize()))
        if since != 0, since == revision {
            return ["type": "unchanged", "revision": String(revision)]
        }
        return RemoteScreenDTO(
            revision: revision,
            cols: snapshot.cols,
            rows: snapshot.rows,
            alternate: snapshot.isAlternateScreen,
            cursorX: snapshot.cursor.x,
            cursorY: snapshot.cursor.y,
            cursorHidden: snapshot.cursor.hidden,
            lines: lines
        ).json()
    }

    func restoreSlots() {
        let slots = frozenSlots
        let wanted = frozenSelectedID
        for slot in slots {
            _ = createSession(cwd: slot.cwd, id: slot.id, select: false, persistNow: false)
        }
        if let wanted, sessions.contains(where: { $0.id == wanted }) {
            selectedID = wanted
        } else {
            selectedID = sessions.first?.id
        }
        applyVisibility()
        persist(immediate: true)
    }

    func applyVisibility() {
        for session in sessions {
            let selected = session.id == selectedID
            session.host.view.isHidden = !selected
        }
        if let selected = sessions.first(where: { $0.id == selectedID }) {
            selected.host.view.window?.makeFirstResponder(selected.host.view)
        }
    }

    private func removeSession(id: String, deleteSlot: Bool) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions.remove(at: index)
        cleanUp(session.host)
        if selectedID == id {
            selectedID = sessions[safe: index]?.id ?? sessions.last?.id
        }
        applyVisibility()
        if deleteSlot {
            frozenSlots.removeAll { $0.id == id }
            if frozenSelectedID == id {
                frozenSelectedID = selectedID
            }
        }
        persist(immediate: true)
    }

    func persist(immediate: Bool = false) {
        let directories = sessions.isEmpty ? frozenSlots.map(\.cwd) : sessions.map(\.cwd)
        collapsedGroups.formIntersection(Set(directories))
        persistDirty = true
        guard !freezeWrites else { return }
        if immediate {
            persistWorkItem?.cancel()
            persistWorkItem = nil
            flushSnapshot()
            return
        }
        persistWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.flushSnapshot()
            }
        }
        persistWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func flushSnapshot() {
        guard persistDirty, !freezeWrites else { return }
        guard layoutRevision < UInt64.max else {
            freezeWrites = true
            note = "布局修订号已达到上限，未覆盖原文件。"
            return
        }
        persistDirty = false
        layoutRevision += 1
        let slots = sessions.isEmpty
            ? frozenSlots
            : sessions.map { LayoutSlot(id: $0.id, cwd: $0.cwd) }
        let selected = sessions.isEmpty ? frozenSelectedID : selectedID
        let snapshot = LayoutSnapshot(
            writeRevision: layoutRevision,
            slots: slots.map { LayoutSnapshot.Slot(id: $0.id, cwd: LayoutPath.normalize($0.cwd)) },
            selectedID: selected,
            collapsedGroups: Array(collapsedGroups),
            windowWidth: windowWidth,
            windowHeight: windowHeight,
            sidebarWidth: sidebarWidth
        )
        do {
            try snapshotStore.save(snapshot)
        } catch SnapshotSaveError.staleRevision {
            note = "忽略过期布局写入。"
        } catch {
            do {
                try snapshotStore.save(snapshot)
            } catch {
                note = "布局未能写入，已保留内存中的最后布局。"
            }
        }
    }

    func gitBranch(for cwd: String) -> String? {
        if let cached = branchCache[cwd] {
            return cached.isEmpty ? nil : cached
        }
        let name = GitWorktree.branchName(at: cwd) ?? ""
        if branchCache.count >= 128 { branchCache.removeAll(keepingCapacity: true) }
        branchCache[cwd] = name
        return name.isEmpty ? nil : name
    }

    var groupedSessions: [(cwd: String, items: [TerminalSession])] {
        var order: [String] = []
        var buckets: [String: [TerminalSession]] = [:]
        for session in sessions {
            if buckets[session.cwd] == nil {
                order.append(session.cwd)
            }
            buckets[session.cwd, default: []].append(session)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    func handle(_ envelope: EventEnvelope) {
        guard let session = sessions.first(where: { $0.id == envelope.terminalSessionID }) else { return }
        guard EventValidation.accept(envelope, identity: identity, sessionID: session.id, ptyGeneration: session.host.ptyGeneration) else { return }
        if envelope.source == "agent" {
            applyAgentEvent(envelope, to: session)
            return
        }
        if envelope.source == "shell", envelope.kind == "codexLaunch" {
            guard session.agentType == "codex",
                  LaunchGate.acceptAgentEvent(currentLaunchID: session.launchID, incomingLaunchID: envelope.launchID),
                  let home = envelope.payload["codexHome"]?.stringValue,
                  home.hasPrefix("/"), !home.utf8.contains(0) else { return }
            if session.nativeCodexHome != home {
                titleObservers.removeValue(forKey: session.id)?.observer.stop()
                session.nativeThreadID = nil
                session.nativeCodexHome = home
                session.activity = AgentActivity(state: "unknown")
                sidebarEpoch += 1
                rescheduleExpiry()
                // PTY titles and helper IPC can arrive on different queues.
                if let title = session.nativeCodexTitle { observeCodexTitle(title, session: session) }
            }
            return
        }
        var sidebarNeedsReload = false
        if envelope.kind == "cwd", envelope.payload["role"]?.stringValue == "top",
           let cwd = envelope.payload["cwd"]?.stringValue {
            let logical = LayoutPath.normalize(cwd)
            session.host.view.linkDirectory = logical
            session.didBecomeReady = true
            if logical != session.cwd {
                let previous = session.cwd
                session.cwd = logical
                branchCache.removeValue(forKey: previous)
                branchCache.removeValue(forKey: logical)
                persist()
                sidebarNeedsReload = true
                session.touch()
            }
        }
        if envelope.kind == "preexec" {
            titleObservers.removeValue(forKey: session.id)?.observer.stop()
            session.nativeCodexHome = nil
            session.nativeCodexTitle = nil
            resetNativeBinding(session)
            daemonObservers.removeValue(forKey: session.id)?.observer.stop()
            claudeWatches.removeValue(forKey: session.id)?.stop()
            if let name = envelope.payload["commandName"]?.stringValue,
               let type = launcherMap.agentType(for: name) {
                session.title = name
                session.agentType = type
                session.launchID = envelope.launchID
                session.activity = AgentActivity(state: "unknown", activeTurnIDs: [], expiresAt: nil)
                session.touch()
                sidebarNeedsReload = true
                rescheduleExpiry()
                if type == "codex" {
                    session.nativeCodexHome = envelope.payload["codexHome"]?.stringValue
                    note = "Codex 状态需要在当前配置的 [tui] 下设置 terminal_title = [\"session-id\"]，无法唯一识别时保持未知。"
                } else if type == "cursor" {
                    note = "Cursor 未上报状态事件，侧栏保持未知。"
                }
            } else {
                session.launchID = nil
                session.agentType = nil
                session.activity = .none
            }
        }
        if envelope.kind == "promptReady" {
            titleObservers.removeValue(forKey: session.id)?.observer.stop()
            session.nativeCodexHome = nil
            session.nativeCodexTitle = nil
            resetNativeBinding(session)
            branchCache.removeValue(forKey: session.cwd)
            daemonObservers.removeValue(forKey: session.id)?.observer.stop()
            claudeWatches.removeValue(forKey: session.id)?.stop()
            session.didBecomeReady = true
            session.title = "Terminal"
            session.agentType = nil
            session.launchID = nil
            session.activity = .none
            session.touch()
            sidebarNeedsReload = true
            rescheduleExpiry()
        }
        if sidebarNeedsReload {
            sidebarEpoch += 1
        }
    }

    private func watchClaude(pid: pid_t, session: TerminalSession) {
        if claudeWatches[session.id]?.pid == pid { return }
        claudeWatches.removeValue(forKey: session.id)?.stop()
        let sessionID = session.id
        let launchID = session.launchID
        let watch = ClaudeSessionWatch(pid: pid) { [weak self] state in
            Task { @MainActor in
                guard let self, let current = self.sessions.first(where: { $0.id == sessionID }),
                      current.launchID == launchID, current.agentType == "claude" else { return }
                guard current.agentState != state else { return }
                current.activity = AgentActivity(state: state)
                current.touch()
                self.sidebarEpoch += 1
                self.rescheduleExpiry()
            }
        }
        claudeWatches[sessionID] = watch
        watch.start()
    }

    private func applyAgentEvent(_ envelope: EventEnvelope, to session: TerminalSession) {
        if !LaunchGate.acceptAgentEvent(currentLaunchID: session.launchID, incomingLaunchID: envelope.launchID) {
            return
        }
        if session.agentType == "codex", session.nativeCodexHome != nil { return }
        if envelope.kind == "codexNativeState" {
            applyNativeState(envelope, to: session)
            return
        }
        if session.agentType == "codex", session.nativeBridgeID != nil { return }
        guard let agentType = session.agentType, let hook = CodexHookAdapter.hookName(from: envelope.payload) else { return }
        if agentType == "claude" || agentType == "cursor" || agentType == "kimi" {
            let turnID = envelope.turnID
                ?? envelope.payload["turn_id"]?.stringValue
                ?? envelope.payload["prompt_id"]?.stringValue
                ?? envelope.payload["generation_id"]?.stringValue
            let previous = session.agentState
            switch agentType {
            case "claude":
                session.activity = ClaudeObserverSettings.apply(session.activity, hook: hook, turnID: turnID, payload: envelope.payload)
            case "kimi":
                session.activity = KimiHookAdapter.apply(session.activity, hook: hook, turnID: turnID, payload: envelope.payload)
            default:
                session.activity = CursorObserverPlugin.apply(session.activity, hook: hook, turnID: turnID, payload: envelope.payload)
            }
            session.touch()
            if previous != session.agentState { sidebarEpoch += 1 }
            rescheduleExpiry()
            if agentType == "claude", let rawPID = envelope.payload["session_pid"]?.intValue,
               let pid = pid_t(exactly: rawPID), pid > 1 {
                watchClaude(pid: pid, session: session)
            }
            return
        }
        guard agentType == "codex" else { return }
        if let launchID = session.launchID, let serviceID = envelope.payload["serviceID"]?.stringValue,
           daemonObservers[session.id] == nil,
           let root = try? CodexService.root(flavor: identity.flavor, sessionID: session.id),
           let socket = CodexService.observationSocket(root: root, serviceID: serviceID, appRunID: identity.appRunID, sessionID: session.id, launchID: launchID) {
            let sessionID = session.id
            let slots = daemonEventSlots
            let observer = CodexDaemonObserver(socketURL: socket) { [weak self] state in
                slots.wait()
                Task { @MainActor in
                    defer { slots.signal() }
                    guard let self, let binding = self.daemonObservers[sessionID], binding.serviceID == serviceID, binding.launchID == launchID,
                          let current = self.sessions.first(where: { $0.id == sessionID }), current.launchID == launchID else { return }
                    let changed = current.agentState != state
                    // The live socket owns this state until its next event or
                    // disconnect. Hook silence is not a daemon timeout.
                    current.activity = AgentActivity(state: state)
                    if changed { current.touch(); self.sidebarEpoch += 1 }
                    self.rescheduleExpiry()
                }
            }
            daemonObservers[sessionID] = (serviceID, launchID, observer)
            observer.start()
        }
        // Stop is an attempted stop; another Hook can require continuation.
        // Owned daemon status is authoritative once its observer is attached.
        if daemonObservers[session.id] != nil { return }
        let turnID = envelope.turnID
            ?? envelope.payload["turn_id"]?.stringValue
            ?? envelope.payload["prompt_id"]?.stringValue
        let previous = session.agentState
        session.activity = CodexHookAdapter.apply(
            session.activity,
            hook: hook,
            turnID: turnID,
            payload: envelope.payload
        )
        session.touch()
        if previous != session.agentState {
            sidebarEpoch += 1
        }
        rescheduleExpiry()
    }

    private func resetNativeBinding(_ session: TerminalSession) {
        nativeBridgeWatches.removeValue(forKey: session.id)?.cancel()
        session.nativeBridgeID = nil
        session.nativeBridgeStarted = 0
        session.nativeBridgeSequence = 0
        session.nativeBridgeDead = false
        session.nativeThreadID = nil
    }

    private func observeCodexTitle(_ title: String, session: TerminalSession) {
        guard session.agentType == "codex", let launchID = session.launchID,
              let home = session.nativeCodexHome, home.hasPrefix("/") else { return }
        session.nativeCodexTitle = title
        let prefix = CodexTitleObserver.sessionPrefix(title: title)
        if let existing = titleObservers[session.id], existing.prefix == prefix, existing.launchID == launchID { return }
        titleObservers.removeValue(forKey: session.id)?.observer.stop()
        session.nativeThreadID = nil
        session.activity = AgentActivity(state: "unknown")
        sidebarEpoch += 1
        rescheduleExpiry()
        guard let prefix else { return }
        let observerID = UUID()
        let sessionID = session.id
        let generation = session.host.ptyGeneration
        let slots = daemonEventSlots
        let socket = URL(fileURLWithPath: home).appendingPathComponent("app-server-control/app-server-control.sock")
        let observer = CodexTitleObserver(socketURL: socket, prefix: prefix) { [weak self] threadID, state in
            slots.wait()
            Task { @MainActor in
                defer { slots.signal() }
                guard let self, self.titleObservers[sessionID]?.id == observerID,
                      let current = self.sessions.first(where: { $0.id == sessionID }),
                      current.launchID == launchID, current.host.ptyGeneration == generation,
                      current.agentType == "codex" else { return }
                let changed = current.agentState != state || current.nativeThreadID != threadID
                current.nativeThreadID = threadID
                current.activity = AgentActivity(state: state)
                if changed { current.touch(); self.sidebarEpoch += 1 }
                self.rescheduleExpiry()
            }
        }
        titleObservers[sessionID] = (observerID, prefix, launchID, observer)
        observer.start()
    }

    private func applyNativeState(_ envelope: EventEnvelope, to session: TerminalSession) {
        guard session.agentType == "codex",
              let bridgeID = envelope.payload["bridgeID"]?.stringValue, UUID(uuidString: bridgeID) != nil,
              let startedText = envelope.payload["started"]?.stringValue, let started = UInt64(startedText), started > 0,
              let sequenceText = envelope.payload["sequence"]?.stringValue, let sequence = UInt64(sequenceText), sequence > 0,
              let rawPID = envelope.payload["bridgePID"]?.intValue, let pid = pid_t(exactly: rawPID), pid > 1,
              let state = envelope.payload["state"]?.stringValue,
              ["unknown", "idle", "working", "needsInput"].contains(state),
              state == "unknown" || envelope.providerSessionID?.isEmpty == false else { return }
        if started < session.nativeBridgeStarted { return }
        if started == session.nativeBridgeStarted {
            guard !session.nativeBridgeDead, bridgeID == session.nativeBridgeID, sequence > session.nativeBridgeSequence else { return }
        }
        let newBridge = session.nativeBridgeID != bridgeID
        if newBridge { session.nativeBridgeDead = false }
        session.nativeBridgeID = bridgeID
        session.nativeBridgeStarted = started
        session.nativeBridgeSequence = sequence
        session.nativeThreadID = envelope.providerSessionID
        let changed = session.agentState != state
        session.activity = AgentActivity(state: state)
        if changed { session.touch(); sidebarEpoch += 1 }
        if newBridge {
            nativeBridgeWatches.removeValue(forKey: session.id)?.cancel()
            let sessionID = session.id
            let launchID = session.launchID
            let watch = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
            watch.setEventHandler { [weak self] in
                Task { @MainActor in
                    guard let self, let current = self.sessions.first(where: { $0.id == sessionID }),
                          current.launchID == launchID, current.nativeBridgeID == bridgeID else { return }
                    current.nativeBridgeDead = true
                    current.nativeThreadID = nil
                    if current.agentState != "unknown" {
                        current.activity = AgentActivity(state: "unknown")
                        current.touch()
                        self.sidebarEpoch += 1
                        self.rescheduleExpiry()
                    }
                    self.nativeBridgeWatches.removeValue(forKey: sessionID)?.cancel()
                }
            }
            nativeBridgeWatches[sessionID] = watch
            watch.resume()
        }
        rescheduleExpiry()
    }

    func markUntrustedIfWorking() {
        var changed = false
        for session in sessions where session.agentState == "working" || session.agentState == "needsInput" {
            session.activity = AgentActivity(state: "unknown", activeTurnIDs: session.activeTurnIDs, expiresAt: nil)
            changed = true
        }
        if changed {
            sidebarEpoch += 1
            rescheduleExpiry()
        }
    }

    private func rescheduleExpiry() {
        expiryTask?.cancel()
        guard let soonest = sessions.compactMap(\.stateExpiresAt).min() else { return }
        expiryTask = Task { @MainActor [weak self] in
            let delay = max(0, soonest.timeIntervalSinceNow)
            let nanoseconds = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.expireDue()
        }
    }

    private func expireDue() {
        let now = Date()
        var changed = false
        for session in sessions {
            let expired = CodexHookAdapter.expire(session.activity, now: now)
            if expired != session.activity {
                session.activity = expired
                changed = true
            }
        }
        if changed {
            sidebarEpoch += 1
        }
        rescheduleExpiry()
    }

    private func environment(for host: TerminalHost) -> [String: String] {
        var environment: [String: String] = [
            "AIE_SOCKET": socketPath,
            "AIE_APP_RUN": identity.appRunID,
            "AIE_SESSION": host.sessionID,
            "AIE_PTY_GEN": String(host.ptyGeneration),
            "AIE_NONCE": identity.nonce,
            "AIE_HELPER": helperPath,
            "AIE_SOURCE": "shell"
        ]
        environment["AIE_WRAPPER_BIN"] = codexWrapperDirectory
        environment["AIE_NATIVE_BRIDGE_VALIDATION"] = identity.flavor == .verification
            && ProcessInfo.processInfo.environment["AIE_NATIVE_BRIDGE_VALIDATION"] == "1" ? "1" : "0"
        environment["AIE_COLOR_OUTPUT"] = appearance.value.preferColorOutput ? "1" : "0"
        return environment
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
