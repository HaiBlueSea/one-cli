import Foundation

enum ResourceLocator {
    static func bundleRoot() -> URL {
        let executable = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        let macos = executable.deletingLastPathComponent()
        if macos.lastPathComponent == "MacOS" {
            return macos.deletingLastPathComponent()
        }
        return macos
    }

    static func resourcesDirectory() -> URL {
        if let url = Bundle.main.resourceURL {
            let zsh = url.appendingPathComponent("Zsh")
            if FileManager.default.fileExists(atPath: zsh.path) {
                return url
            }
        }
        let contents = bundleRoot()
        let bundled = contents.appendingPathComponent("Resources")
        if FileManager.default.fileExists(atPath: bundled.appendingPathComponent("Zsh").path) {
            return bundled
        }
        return URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources")
    }

    static func zshDotDir() -> URL {
        resourcesDirectory().appendingPathComponent("Zsh")
    }

    static func helperURL() -> URL {
        let bundled = bundleRoot().appendingPathComponent("Helpers/AIEHookHelper")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        return URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("AIEHookHelper")
    }

    static func launchersURL() -> URL {
        resourcesDirectory().appendingPathComponent("launchers.json")
    }

    static func codexWrapperURL() -> URL {
        resourcesDirectory().appendingPathComponent("Wrappers/codex")
    }

    static func wrappersDirectory() -> URL {
        resourcesDirectory().appendingPathComponent("Wrappers")
    }

    static func remoteHelperURL() -> URL {
        let bundled = bundleRoot().appendingPathComponent("Helpers/AIERemoteHelper")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        return URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("AIERemoteHelper")
    }

    static func remoteWebDirectory() -> URL {
        let bundled = resourcesDirectory().appendingPathComponent("RemoteWeb")
        if FileManager.default.fileExists(atPath: bundled.appendingPathComponent("index.html").path) {
            return bundled
        }
        return URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/RemoteWeb")
    }
}
