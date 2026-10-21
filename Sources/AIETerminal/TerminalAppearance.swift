import AIETerminalCore
import AppKit
import Combine
import SwiftUI
import SwiftTerm

enum TerminalTheme: String, CaseIterable, Identifiable {
    case catppuccinMocha = "Catppuccin Mocha"
    case tokyoNight = "Tokyo Night Night"
    case dracula = "Dracula"
    case nord = "Nord"
    case gruvboxDark = "Gruvbox Dark"
    case rosePine = "Rosé Pine"
    case kanagawaWave = "Kanagawa Wave"

    var id: String { rawValue }
    var isLight: Bool {
        let red = Double((backgroundHex >> 16) & 255) / 255
        let green = Double((backgroundHex >> 8) & 255) / 255
        let blue = Double(backgroundHex & 255) / 255
        return red * 0.2126 + green * 0.7152 + blue * 0.0722 > 0.6
    }
    var backgroundHex: UInt32 {
        switch self {
        case .catppuccinMocha: 0x1e1e2e
        case .tokyoNight: 0x1a1b26
        case .dracula: 0x282a36
        case .nord: 0x2e3440
        case .gruvboxDark: 0x282828
        case .rosePine: 0x191724
        case .kanagawaWave: 0x1f1f28
        }
    }
    var foregroundHex: UInt32 {
        switch self {
        case .catppuccinMocha: 0xcdd6f4
        case .tokyoNight: 0xc0caf5
        case .dracula: 0xf8f8f2
        case .nord: 0xd8dee9
        case .gruvboxDark: 0xebdbb2
        case .rosePine: 0xe0def4
        case .kanagawaWave: 0xdcd7ba
        }
    }
    var accentHex: UInt32 {
        switch self {
        case .catppuccinMocha: 0xa6e3a1
        case .tokyoNight: 0x9ece6a
        case .dracula: 0x50fa7b
        case .nord: 0xa3be8c
        case .gruvboxDark: 0xb8bb26
        case .rosePine: 0x9ccfd8
        case .kanagawaWave: 0x98bb6c
        }
    }
    var branchHex: UInt32 {
        switch self {
        case .catppuccinMocha: 0xf5c2e7
        case .tokyoNight: 0xbb9af7
        case .dracula: 0xff79c6
        case .nord: 0xb48ead
        case .gruvboxDark: 0xd3869b
        case .rosePine: 0xeb6f92
        case .kanagawaWave: 0x957fb8
        }
    }
    var ansi: [UInt32] {
        switch self {
        case .catppuccinMocha: [0x45475a,0xf38ba8,0xa6e3a1,0xf9e2af,0x89b4fa,0xf5c2e7,0x94e2d5,0xbac2de,0x585b70,0xf38ba8,0xa6e3a1,0xf9e2af,0x89b4fa,0xf5c2e7,0x94e2d5,0xa6adc8]
        case .tokyoNight: [0x15161e,0xf7768e,0x9ece6a,0xe0af68,0x7aa2f7,0xbb9af7,0x7dcfff,0xa9b1d6,0x414868,0xf7768e,0x9ece6a,0xe0af68,0x7aa2f7,0xbb9af7,0x7dcfff,0xc0caf5]
        case .dracula: [0x21222c,0xff5555,0x50fa7b,0xf1fa8c,0xbd93f9,0xff79c6,0x8be9fd,0xf8f8f2,0x6272a4,0xff6e6e,0x69ff94,0xffffa5,0xd6acff,0xff92df,0xa4ffff,0xffffff]
        case .nord: [0x3b4252,0xbf616a,0xa3be8c,0xebcb8b,0x81a1c1,0xb48ead,0x88c0d0,0xe5e9f0,0x4c566a,0xbf616a,0xa3be8c,0xebcb8b,0x81a1c1,0xb48ead,0x8fbcbb,0xeceff4]
        case .gruvboxDark: [0x282828,0xcc241d,0x98971a,0xd79921,0x458588,0xb16286,0x689d6a,0xa89984,0x928374,0xfb4934,0xb8bb26,0xfabd2f,0x83a598,0xd3869b,0x8ec07c,0xebdbb2]
        case .rosePine: [0x26233a,0xeb6f92,0x31748f,0xf6c177,0x9ccfd8,0xc4a7e7,0xebbcba,0xe0def4,0x6e6a86,0xeb6f92,0x31748f,0xf6c177,0x9ccfd8,0xc4a7e7,0xebbcba,0xe0def4]
        case .kanagawaWave: [0x16161d,0xc34043,0x76946a,0xc0a36e,0x7e9cd8,0x957fb8,0x6a9589,0xc8c093,0x727169,0xe82424,0x98bb6c,0xe6c384,0x7fb4ca,0x938aa9,0x7aa89f,0xdcd7ba]
        }
    }
    var background: NSColor { NSColor(rgb: backgroundHex) }
    var foreground: NSColor { NSColor(rgb: foregroundHex) }
    var accent: NSColor { NSColor(rgb: accentHex) }
    var branch: NSColor { NSColor(rgb: branchHex) }
}

extension TerminalTheme: Codable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "Dracula": self = .dracula
        case "Nord": self = .nord
        case "Tokyo Night Night": self = .tokyoNight
        case "Gruvbox Dark": self = .gruvboxDark
        case "Rosé Pine", "Rose Pine": self = .rosePine
        case "Kanagawa Wave": self = .kanagawaWave
        case "Catppuccin Mocha", "Midnight": self = .catppuccinMocha
        default: self = .catppuccinMocha
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(srgbRed: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, alpha: 1)
    }
}

struct TerminalAppearance: Codable, Equatable {
    var fontSize: Double = 13
    var fontFamily = "Hack"
    var lineSpacing: Double = 1.1
    var preferColorOutput = true
    var thinStrokes = true
    var theme: TerminalTheme = .catppuccinMocha

    init() {}

    enum CodingKeys: String, CodingKey { case fontSize, fontFamily, lineSpacing, preferColorOutput, thinStrokes, theme }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fontSize = try values.decodeIfPresent(Double.self, forKey: .fontSize) ?? 13
        fontFamily = try values.decodeIfPresent(String.self, forKey: .fontFamily) ?? "Hack"
        // Existing preferences keep their original terminal geometry.
        lineSpacing = try values.decodeIfPresent(Double.self, forKey: .lineSpacing) ?? 1.0
        preferColorOutput = try values.decodeIfPresent(Bool.self, forKey: .preferColorOutput) ?? true
        thinStrokes = try values.decodeIfPresent(Bool.self, forKey: .thinStrokes) ?? true
        theme = try values.decodeIfPresent(TerminalTheme.self, forKey: .theme) ?? .catppuccinMocha
    }

    func sanitized() -> TerminalAppearance {
        var copy = self
        copy.fontSize = fontSize.isFinite ? min(32, max(9, fontSize)) : 13
        if !TerminalFontCatalog.families.contains(fontFamily) { copy.fontFamily = "Hack" }
        copy.lineSpacing = lineSpacing.isFinite ? min(1.5, max(1.0, lineSpacing)) : 1.1
        return copy
    }
}

@MainActor
final class TerminalAppearanceStore: ObservableObject {
    @Published private(set) var value: TerminalAppearance
    @Published private(set) var saveError: String?
    let url: URL
    init(url: URL) {
        self.url = url
        _ = TerminalFontCatalog.registrationFailures
        value = ((try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(TerminalAppearance.self, from: $0) } ?? TerminalAppearance()).sanitized()
    }
    func update(_ edit: (inout TerminalAppearance) -> Void) {
        var next = value
        edit(&next)
        next = next.sanitized()
        guard next != value else { return }
        value = next
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: url, options: .atomic)
            saveError = nil
        } catch { saveError = "外观设置未能保存。" }
    }
    var font: NSFont {
        TerminalFontCatalog.font(family: value.fontFamily, size: value.fontSize)
    }
    func apply(to view: LocalProcessTerminalView) {
        view.fontSmoothing = !value.thinStrokes
        if view.font.fontName != font.fontName || view.font.pointSize != font.pointSize { view.font = font }
        if view.lineSpacing != value.lineSpacing { view.lineSpacing = value.lineSpacing }
        view.nativeForegroundColor = value.theme.foreground
        view.nativeBackgroundColor = value.theme.background
        view.installColors(value.theme.ansi.map { SwiftTerm.Color(red: UInt16(($0 >> 16) & 255) * 257, green: UInt16(($0 >> 8) & 255) * 257, blue: UInt16($0 & 255) * 257) })
    }
}

private struct ThemeEnvironmentKey: EnvironmentKey { static let defaultValue = TerminalTheme.catppuccinMocha }
extension EnvironmentValues {
    var terminalTheme: TerminalTheme {
        get { self[ThemeEnvironmentKey.self] }
        set { self[ThemeEnvironmentKey.self] = newValue }
    }
}

@MainActor
final class AppearanceWindowController: NSWindowController {
    init(store: TerminalAppearanceStore) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 650), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "设置"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AppearanceSettingsView(store: store))
        window.center()
        super.init(window: window)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

private struct AppearanceSettingsView: View {
    @ObservedObject var store: TerminalAppearanceStore
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                if let image = NSImage(named: "AppIcon") { Image(nsImage: image).resizable().frame(width: 52, height: 52) }
                VStack(alignment: .leading, spacing: 5) {
                    Text("终端外观").font(.system(size: 22, weight: .semibold))
                    Text("字体、行距和主题立即生效，并自动保存。").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Text("快速选择").font(.system(size: 12)).foregroundStyle(.secondary)
                ForEach(["Hack", "JetBrains Mono", "Fira Code"], id: \.self) { family in
                    Button(family) { store.update { $0.fontFamily = family; $0.fontSize = 13; $0.lineSpacing = 1.1 } }
                        .controlSize(.small)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 25, verticalSpacing: 18) {
                GridRow {
                    Text("字体")
                    Picker("字体", selection: Binding(get: { store.value.fontFamily }, set: { v in store.update { $0.fontFamily = v } })) {
                        ForEach(TerminalFontCatalog.families, id: \.self) { family in
                            Text(family).font(.custom(TerminalFontCatalog.font(family: family, size: 13).fontName, size: 13)).tag(family)
                        }
                    }.labelsHidden().frame(width: 210)
                }
                GridRow {
                    Text("笔画")
                    Toggle("细笔画（保留粗体强调）", isOn: Binding(get: { store.value.thinStrokes }, set: { v in store.update { $0.thinStrokes = v } }))
                }
                GridRow {
                    Text("行距")
                    HStack(spacing: 12) {
                        Slider(value: Binding(get: { store.value.lineSpacing }, set: { v in store.update { $0.lineSpacing = v } }), in: 1.0...1.5, step: 0.05)
                            .frame(width: 160).accessibilityLabel("终端行距")
                        Text(String(format: "%.2f×", store.value.lineSpacing)).monospacedDigit().frame(width: 48, alignment: .leading)
                    }
                }
                GridRow {
                    Text("字号")
                    HStack {
                        Stepper(value: Binding(get: { store.value.fontSize }, set: { v in store.update { $0.fontSize = v } }), in: 9...32, step: 1) {
                            Text("\(Int(store.value.fontSize)) pt").monospacedDigit().frame(width: 50, alignment: .leading)
                        }.frame(width: 130)
                        Text("⌘ + / ⌘ −").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("主题")
                    Picker("主题", selection: Binding(get: { store.value.theme }, set: { v in store.update { $0.theme = v } })) {
                        ForEach(TerminalTheme.allCases) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().frame(width: 210)
                }
                GridRow {
                    Text("命令颜色")
                    VStack(alignment: .leading, spacing: 5) {
                        Toggle("启用彩色输出默认值", isOn: Binding(get: { store.value.preferColorOutput }, set: { v in store.update { $0.preferColorOutput = v } }))
                        Text("新建终端生效；具体颜色由命令决定。").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                Text("字体与配色预览").font(.system(size: 10, weight: .semibold)).opacity(0.5)
                Text("~/Projects/AI Terminal").foregroundStyle(Color(nsColor: store.value.theme.accent))
                Text("❯ codex  --model gpt\n中文输入 · Hello, terminal!\n0O 1Il  {} []  => !=  ~/Projects")
                    .lineSpacing(store.font.pointSize * (store.value.lineSpacing - 1))
                HStack(spacing: 18) { Text("Regular"); Text("Bold").bold(); Text("Italic").italic() }
                HStack(spacing: 6) { ForEach(Array(store.value.theme.ansi.prefix(8).enumerated()), id: \.offset) { _, rgb in Capsule().fill(Color(nsColor: NSColor(rgb: rgb))).frame(width: 26, height: 5) } }
            }
            .font(.custom(store.font.fontName, size: store.value.fontSize))
            .foregroundStyle(Color(nsColor: store.value.theme.foreground))
            .frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(Color(nsColor: store.value.theme.background), in: RoundedRectangle(cornerRadius: 12))
            HStack {
                if let error = store.saveError { Text(error).foregroundStyle(.red).font(.caption) }
                Spacer()
                Button("恢复默认") { store.update { $0 = TerminalAppearance() } }
            }
        }.padding(28).frame(width: 620)
        }.frame(width: 620)
    }
}
