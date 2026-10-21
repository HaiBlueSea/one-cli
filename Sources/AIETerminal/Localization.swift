import AIETerminalCore
import Combine

@MainActor
final class L10n: ObservableObject {
    static let shared = L10n()
    @Published var language: AppLanguage = .chinese

    static func text(_ key: String, _ arguments: CVarArg...) -> String {
        shared.language.format(key, arguments: arguments)
    }

    static func terminalText(_ key: String) -> String {
        let keys = ["Find": "查找", "Previous": "上一个", "Next": "下一个", "Close": "关闭",
                    "Case Sensitive": "区分大小写", "Regex": "正则表达式", "Whole Word": "全词匹配", "Word": "整词"]
        return text(keys[key] ?? key)
    }
}
