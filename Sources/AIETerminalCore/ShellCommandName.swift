import Foundation

public enum ShellCommandName: Sendable {
    private static let skippedPrefixes: Set<String> = [
        "command", "env", "exec", "nice", "nohup", "time", "builtin", "noglob"
    ]

    public static func parse(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let tokens = tokenize(trimmed)
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if isAssignment(token) {
                index += 1
                continue
            }
            if skippedPrefixes.contains(token) {
                index += 1
                while index < tokens.count, tokens[index].hasPrefix("-") {
                    let option = tokens[index]
                    index += 1
                    if option == "--" { break }
                    let takesValue: Bool
                    switch token {
                    case "env": takesValue = ["-u", "--unset", "-C", "--chdir", "-P"].contains(option)
                    case "nice": takesValue = ["-n", "--adjustment"].contains(option)
                    case "exec": takesValue = option == "-a"
                    default: takesValue = false
                    }
                    if takesValue {
                        guard index < tokens.count, !["|", "||", "&&", ";"].contains(tokens[index]) else { return nil }
                        index += 1
                    }
                }
                continue
            }
            if token == "|" || token == "||" || token == "&&" || token == ";" {
                return nil
            }
            return token
        }
        return nil
    }

    public static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for character in line {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\" && quote != "'" {
                escaped = true
                continue
            }
            if let active = quote {
                if character == active {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                continue
            }
            if character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(character)
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private static func isAssignment(_ token: String) -> Bool {
        guard let equal = token.firstIndex(of: "=") else { return false }
        let name = token[..<equal]
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}

public struct LauncherMap: Sendable {
    public static let knownTypes: Set<String> = ["claude", "codex", "cursor", "kimi"]

    public var launchers: [String: String]

    public init(launchers: [String: String]) {
        self.launchers = launchers
    }

    public static func load(from url: URL) throws -> LauncherMap {
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(File.self, from: data)
        return LauncherMap(launchers: decoded.launchers)
    }

    public func agentType(for commandName: String) -> String? {
        guard let type = launchers[commandName], Self.knownTypes.contains(type) else {
            return nil
        }
        return type
    }

    public var invalidMappings: [String] {
        launchers.compactMap { name, type in
            Self.knownTypes.contains(type) ? nil : name
        }.sorted()
    }

    private struct File: Codable {
        var launchers: [String: String]
    }
}
