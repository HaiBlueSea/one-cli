import AppKit
import CoreText
import Foundation

enum TerminalFontCatalog {
    static let families = ["Hack", "JetBrains Mono", "Fira Code", "System Mono", "Menlo", "Monaco"]
    private static let names = ["Hack": "Hack-Regular", "JetBrains Mono": "JetBrainsMono-Regular", "Fira Code": "FiraCode-Regular"]

    @MainActor static let registrationFailures: [String] = {
        let directory = ResourceLocator.resourcesDirectory().appendingPathComponent("Fonts")
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var failures: [String] = []
        for file in files where file.pathExtension == "ttf" {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(file as CFURL, .process, &error) {
                let code = error.map { CFErrorGetCode($0.takeRetainedValue()) }
                if code != CTFontManagerError.alreadyRegistered.rawValue { failures.append(file.lastPathComponent) }
            }
        }
        return failures
    }()

    @MainActor static func font(family: String, size: Double) -> NSFont {
        _ = registrationFailures
        if family == "System Mono" { return .monospacedSystemFont(ofSize: size, weight: .regular) }
        return NSFont(name: names[family] ?? family, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
