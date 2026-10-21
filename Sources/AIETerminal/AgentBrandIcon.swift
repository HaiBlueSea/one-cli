import AppKit
import Foundation

@MainActor
enum AgentBrandIcon {
    private static let images: [String: NSImage] = {
        var result: [String: NSImage] = [:]
        let labels = ["codex": "OpenAI Codex", "kimi": "Kimi", "claude": "Claude", "cursor": "Cursor"]
        for (type, file) in ["codex": "openai", "kimi": "kimi", "claude": "claude", "cursor": "cursor"] {
            let url = ResourceLocator.resourcesDirectory().appendingPathComponent("AgentIcons/\(file).pdf")
            if let image = NSImage(contentsOf: url) {
                image.isTemplate = true
                image.accessibilityDescription = labels[type] ?? type
                result[type] = image
            }
        }
        return result
    }()

    static func image(for type: String?) -> NSImage? { type.flatMap { images[$0] } }

    static func accessibilityLabel(for type: String?) -> String {
        switch type {
        case "codex": "OpenAI Codex"
        case "kimi": "Kimi"
        case "claude": "Claude"
        case "cursor": "Cursor"
        default: "Terminal"
        }
    }
}
