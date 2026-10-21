import Foundation

public enum AppFlavor: String, Sendable {
    case development
    case release
    case verification

    public var bundleIdentifier: String {
        switch self {
        case .development:
            return "com.aiterminal.dev"
        case .release:
            return "com.aiterminal.app"
        case .verification:
            return "com.aiterminal.verification"
        }
    }

    public var displayName: String {
        switch self {
        case .development:
            return "One Cli Dev"
        case .release:
            return "One Cli"
        case .verification:
            return "One Cli Verification"
        }
    }

    public static func matching(_ bundleIdentifier: String?) -> AppFlavor {
        switch bundleIdentifier {
        case AppFlavor.release.bundleIdentifier:
            return .release
        case AppFlavor.verification.bundleIdentifier:
            return .verification
        default:
            return .development
        }
    }

    public var remotePort: UInt16 {
        switch self {
        case .development: return 18780
        case .release: return 18781
        case .verification: return 18782
        }
    }

    public var supportDirectoryName: String {
        switch self {
        case .development:
            return "AITerminalDev"
        case .release:
            return "AITerminal"
        case .verification:
            return "AITerminalVerification"
        }
    }
}

public struct AppIdentity: Sendable {
    public var flavor: AppFlavor
    public var appRunID: String
    public var nonce: String

    public init(flavor: AppFlavor, appRunID: String = UUID().uuidString, nonce: String = UUID().uuidString) {
        self.flavor = flavor
        self.appRunID = appRunID
        self.nonce = nonce
    }
}

public enum RuntimePaths: Sendable {
    private final class InstallCache: @unchecked Sendable {
        let lock = NSLock()
        var zshDotDirs: [String: URL] = [:]
        var helpers: [String: URL] = [:]
        var wrappers: [String: URL] = [:]
    }

    private static let cache = InstallCache()

    public static func supportDirectory(flavor: AppFlavor) throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = root.appendingPathComponent(flavor.supportDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public static func socketURL(flavor: AppFlavor, appRunID: String) throws -> URL {
        let ipc = try supportDirectory(flavor: flavor).appendingPathComponent("ipc", isDirectory: true)
        try FileManager.default.createDirectory(at: ipc, withIntermediateDirectories: true)
        let shortID = String(appRunID.replacingOccurrences(of: "-", with: "").prefix(12))
        return ipc.appendingPathComponent("\(shortID).sock")
    }

    public static func probeLogURL(flavor: AppFlavor, appRunID: String) throws -> URL {
        let logs = try supportDirectory(flavor: flavor).appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("\(appRunID).jsonl")
    }

    public static func installZshDotDir(from source: URL, flavor: AppFlavor) throws -> URL {
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if let existing = cache.zshDotDirs[flavor.rawValue] {
            return existing
        }
        let dest = try supportDirectory(flavor: flavor).appendingPathComponent("zsh", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let items = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        for item in items {
            let target = dest.appendingPathComponent(item.lastPathComponent)
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: item, to: target)
        }
        cache.zshDotDirs[flavor.rawValue] = dest
        return dest
    }

    public static func installHelper(from source: URL, flavor: AppFlavor) throws -> URL {
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if let existing = cache.helpers[flavor.rawValue] {
            return existing
        }
        let bin = try supportDirectory(flavor: flavor).appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let dest = bin.appendingPathComponent("AIEHookHelper")
        let temp = dest.appendingPathExtension("new")
        if FileManager.default.fileExists(atPath: temp.path) {
            try FileManager.default.removeItem(at: temp)
        }
        try FileManager.default.copyItem(at: source, to: temp)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temp.path)
        if FileManager.default.fileExists(atPath: dest.path) {
            _ = try FileManager.default.replaceItemAt(dest, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: dest)
        }
        cache.helpers[flavor.rawValue] = dest
        return dest
    }

    public static func installCodexWrapper(from source: URL, flavor: AppFlavor) throws -> URL {
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if let existing = cache.wrappers[flavor.rawValue] {
            return existing
        }
        let bin = try supportDirectory(flavor: flavor).appendingPathComponent("codex-wrapper", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let dest = bin.appendingPathComponent("codex")
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: source, to: dest)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        cache.wrappers[flavor.rawValue] = dest
        return dest
    }

    public static func installWrappers(from directory: URL, flavor: AppFlavor) throws -> URL {
        cache.lock.lock()
        defer { cache.lock.unlock() }
        let bin = try supportDirectory(flavor: flavor).appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for source in items where !source.lastPathComponent.hasPrefix(".") {
            let dest = bin.appendingPathComponent(source.lastPathComponent)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: source, to: dest)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        }
        return bin
    }
}
