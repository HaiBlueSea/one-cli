import AppKit
import SwiftUI

private struct SidebarPalette {
    let theme: TerminalTheme
    var background: Color {
        let toward: NSColor = theme.isLight ? .white : .black
        return Color(nsColor: theme.background.blended(withFraction: 0.06, of: toward) ?? theme.background)
    }
    var selectedRow: Color { Color(nsColor: theme.foreground).opacity(theme.isLight ? 0.10 : 0.12) }
    var accent: Color { Color(nsColor: theme.accent) }
    var folder: Color { Color(nsColor: theme.accent) }
    var folderIcon: Color { Color(nsColor: theme.foreground).opacity(theme.isLight ? 0.72 : 0.62) }
    var branchFill: Color { Color(nsColor: NSColor(rgb: 0x402939)) }
    var branchText: Color { Color(nsColor: NSColor(rgb: 0xFF789E)) }
    var tree: Color { Color(nsColor: theme.foreground.withAlphaComponent(theme.isLight ? 0.35 : 0.42)) }
    var subtitle: Color { Color(nsColor: theme.foreground).opacity(theme.isLight ? 0.72 : 0.62) }
    var title: Color { Color(nsColor: theme.foreground).opacity(0.96) }
    var header: Color { Color(nsColor: theme.foreground).opacity(theme.isLight ? 0.62 : 0.5) }
}

struct SessionSidebar: View {
    @ObservedObject var coordinator: SessionCoordinator
    @ObservedObject private var localization = L10n.shared
    @ObservedObject private var appearance: TerminalAppearanceStore
    private var palette: SidebarPalette { SidebarPalette(theme: appearance.value.theme) }
    init(coordinator: SessionCoordinator) {
        self.coordinator = coordinator
        self.appearance = coordinator.appearance
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                if let image = NSImage(contentsOf: ResourceLocator.resourcesDirectory().appendingPathComponent("AppIcon.png"))
                    ?? NSImage(named: "AppIcon") {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: 68, height: 68)
                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("One Cli")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(palette.title)
                    Text(L10n.text("所有 Agent，尽在一处。"))
                        .font(.system(size: 12))
                        .foregroundStyle(palette.subtitle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 4)
            .padding(.top, 6)
            HStack(spacing: 8) {
                Text(L10n.text("当前任务"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.header)
                    .fixedSize()
                Text("\(coordinator.sessions.count)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.subtitle)
                Rectangle()
                    .fill(palette.tree)
                    .frame(height: 1)
            }
            .padding(.horizontal, 4)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(coordinator.groupedSessions, id: \.cwd) { group in
                        DirectoryGroupNode(
                            cwd: group.cwd,
                            sessions: group.items,
                            branch: coordinator.gitBranch(for: group.cwd),
                            collapsed: coordinator.collapsedGroups.contains(group.cwd),
                            selectedID: coordinator.selectedID,
                            onToggle: {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    coordinator.toggleGroup(group.cwd)
                                }
                            },
                            onSelect: { id in coordinator.select(id: id) },
                            onClose: { id in
                                coordinator.closeSession(id: id)
                            }
                        )
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(.vertical, 10)
        .padding(.leading, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.background)
        .environment(\.terminalTheme, appearance.value.theme)
        .environment(\.locale, Locale(identifier: localization.language.rawValue))
        .focusable(false)
    }
}

private struct DirectoryGroupNode: View {
    @Environment(\.terminalTheme) private var theme
    private var palette: SidebarPalette { SidebarPalette(theme: theme) }
    let cwd: String
    let sessions: [TerminalSession]
    let branch: String?
    let collapsed: Bool
    let selectedID: String?
    let onToggle: () -> Void
    let onSelect: (String) -> Void
    let onClose: (String) -> Void

    private var folderTitle: String {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        if name.hasPrefix("[") { return name }
        return "[\(name)]"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(palette.subtitle)
                        .frame(width: 10)
                    Image(systemName: "folder")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.folderIcon)
                    Text(folderTitle)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(palette.folder)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    if let branch, !branch.isEmpty {
                        GitBranchBadge(name: branch)
                            .layoutPriority(-1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(cwd)

            if !collapsed {
                Rectangle()
                    .fill(palette.tree)
                    .frame(width: SidebarTree.lineWidth, height: 8)
                    .padding(.leading, SidebarTree.stemX - SidebarTree.lineWidth / 2)
                ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                    SessionTreeRow(
                        session: session,
                        selected: session.id == selectedID,
                        isLast: index == sessions.count - 1,
                        onSelect: { onSelect(session.id) },
                        onClose: { onClose(session.id) }
                    )
                }
            }
        }
    }
}

private struct SessionTreeRow: View {
    @Environment(\.terminalTheme) private var theme
    private var palette: SidebarPalette { SidebarPalette(theme: theme) }
    @ObservedObject private var localization = L10n.shared
    @ObservedObject var session: TerminalSession
    let selected: Bool
    let isLast: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        Button(action: onSelect) {
            ZStack(alignment: .leading) {
                if selected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(palette.selectedRow)
                        .padding(.leading, 3)
                    Capsule()
                        .fill(palette.accent)
                        .frame(width: 3)
                        .padding(.vertical, 8)
                }
                HStack(spacing: 0) {
                    Color.clear.frame(width: SidebarTree.glyphLeading - SidebarTree.inset)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 5) {
                            SessionGlyph(agentType: session.agentType)
                            Text(session.displayName)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(palette.title)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            SessionStatus(state: session.agentState)
                                .fixedSize()
                            Spacer(minLength: 0)
                        }
                        Text(session.subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(palette.subtitle)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.leading, SidebarTree.subtitleIndent)
                    }
                    .padding(.vertical, 8)
                    .padding(.trailing, 6)
                }
                .padding(.leading, SidebarTree.inset)
                .padding(.trailing, 6)
                .background {
                    SessionTreeLines(isLast: isLast)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .contextMenu {
            Button(L10n.text("关闭此终端"), role: .destructive, action: onClose)
        }
    }
}

private enum SidebarTree {
    static let inset: CGFloat = 6
    static let stemX: CGFloat = 29
    static let glyphLeading: CGFloat = 70
    static let iconGap: CGFloat = 10
    static let cornerX: CGFloat = stemX + 24
    static let subtitleIndent: CGFloat = 18 + 5
    static let iconY: CGFloat = 17
    static let subtitleY: CGFloat = 39
    static let lineWidth: CGFloat = 1.4
}

private struct SessionTreeLines: View {
    @Environment(\.terminalTheme) private var theme
    private var palette: SidebarPalette { SidebarPalette(theme: theme) }
    let isLast: Bool

    var body: some View {
        Canvas { context, size in
            let cornerX = SidebarTree.cornerX
            let subtitleX = SidebarTree.glyphLeading + SidebarTree.subtitleIndent - SidebarTree.iconGap
            var path = Path()
            path.move(to: CGPoint(x: SidebarTree.stemX, y: 0))
            path.addLine(to: CGPoint(x: SidebarTree.stemX, y: isLast ? SidebarTree.iconY : size.height))
            path.move(to: CGPoint(x: SidebarTree.stemX, y: SidebarTree.iconY))
            path.addLine(to: CGPoint(x: SidebarTree.glyphLeading - SidebarTree.iconGap, y: SidebarTree.iconY))
            path.move(to: CGPoint(x: cornerX, y: SidebarTree.iconY))
            path.addLine(to: CGPoint(x: cornerX, y: SidebarTree.subtitleY))
            path.addLine(to: CGPoint(x: subtitleX, y: SidebarTree.subtitleY))
            context.stroke(
                path,
                with: .color(palette.tree),
                style: StrokeStyle(lineWidth: SidebarTree.lineWidth, lineCap: .butt, lineJoin: .miter)
            )
        }
    }
}

private struct WorkingSpinner: View {
    @Environment(\.terminalTheme) private var theme
    @State private var rotating = false

    var body: some View {
        ZStack {
            ForEach(0..<8) { segment in
                RoundedRectangle(cornerRadius: 0.6)
                    .fill(Color(nsColor: theme.accent).opacity(0.28 + Double(segment) * 0.08))
                    .frame(width: 2, height: 3.5)
                    .offset(y: -4.5)
                    .rotationEffect(.degrees(Double(segment) * 45))
            }
        }
        .frame(width: 13, height: 13)
        .rotationEffect(.degrees(rotating ? 360 : 0))
        .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: rotating)
        .onAppear { rotating = true }
        .accessibilityHidden(true)
    }
}

private struct SessionStatus: View {
    @ObservedObject private var localization = L10n.shared
    @Environment(\.terminalTheme) private var theme
    let state: String

    private var label: String? {
        switch state {
        case "working": L10n.text("运行中")
        case "idle": L10n.text("就绪")
        case "needsInput": L10n.text("等待输入")
        case "unknown": L10n.text("状态未知")
        default: nil
        }
    }

    private var dotColor: Color {
        switch state {
        case "idle": Color(nsColor: NSColor(rgb: theme.ansi[2]))
        case "needsInput": Color(nsColor: NSColor(rgb: theme.ansi[3]))
        default: Color(nsColor: theme.foreground).opacity(0.45)
        }
    }

    var body: some View {
        if let label {
            HStack(spacing: 5) {
                if state == "working" {
                    WorkingSpinner()
                } else {
                    Circle().fill(dotColor).frame(width: 6, height: 6)
                }
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(SidebarPalette(theme: theme).subtitle)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
        }
    }
}

private struct SessionGlyph: View {
    @Environment(\.terminalTheme) private var theme
    let agentType: String?

    var body: some View {
        Group {
            if let image = AgentBrandIcon.image(for: agentType) {
                Image(nsImage: image).resizable().scaledToFit()
                    .accessibilityLabel(AgentBrandIcon.accessibilityLabel(for: agentType))
            } else {
                Image(systemName: "terminal")
                    .font(.system(size: 15, weight: .medium))
                    .accessibilityLabel(L10n.text("终端"))
            }
        }
        .foregroundStyle(agentType == nil ? Color(nsColor: theme.accent) : SidebarPalette(theme: theme).title)
        .frame(width: 18, height: 18)
    }
}

private struct GitBranchBadge: View {
    @Environment(\.terminalTheme) private var theme
    private var palette: SidebarPalette { SidebarPalette(theme: theme) }
    let name: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 9, weight: .semibold))
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(palette.branchText)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(palette.branchFill)
        .clipShape(Capsule())
    }
}

enum GitWorktree {
    static func branchName(at directory: String) -> String? {
        var url = URL(fileURLWithPath: directory)
        while true {
            let git = url.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: git.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    return parseHEAD(git.appendingPathComponent("HEAD"))
                }
                if let gitDir = gitdirPointer(at: git) {
                    return parseHEAD(gitDir.appendingPathComponent("HEAD"))
                }
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
    }

    private static func gitdirPointer(at gitFile: URL) -> URL? {
        guard let text = try? String(contentsOf: gitFile, encoding: .utf8) else { return nil }
        let prefix = "gitdir:"
        guard text.lowercased().hasPrefix(prefix) else { return nil }
        let raw = text.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("/") {
            return URL(fileURLWithPath: raw)
        }
        return gitFile.deletingLastPathComponent().appendingPathComponent(raw)
    }

    private static func parseHEAD(_ head: URL) -> String? {
        guard let text = try? String(contentsOf: head, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }
        let refPrefix = "ref:"
        if text.lowercased().hasPrefix(refPrefix) {
            let ref = text.dropFirst(refPrefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            return URL(fileURLWithPath: ref).lastPathComponent
        }
        return String(text.prefix(7))
    }
}
