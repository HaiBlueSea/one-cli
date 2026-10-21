import AppKit
import SwiftTerm

enum TerminalLink {
    /// Resolve against the validated top-level Shell directory, never the App cwd or OSC 7.
    static func resolve(_ link: String, directory: String) -> URL? {
        guard !link.isEmpty, !link.contains("\0") else { return nil }
        let base = URL(fileURLWithPath: directory, isDirectory: true)
        func existingFile(_ path: String) -> URL? {
            let expanded = NSString(string: path).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded, relativeTo: base).standardizedFileURL
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        func localFile(_ path: String) -> URL? {
            if let file = existingFile(path) { return file }
            // Preserve real filenames containing ':' or '#' before stripping source locations.
            let withoutFragment = path.components(separatedBy: "#").first ?? path
            let withoutLocation = withoutFragment.replacingOccurrences(of: #":[0-9]+(?::[0-9]+)?$"#, with: "", options: .regularExpression)
            return existingFile(withoutLocation)
        }
        if let file = existingFile(link) { return file }
        if let url = URL(string: link), let scheme = url.scheme?.lowercased() {
            if scheme == "file" {
                guard url.host == nil || url.host == "" || url.host == "localhost" || url.host == ProcessInfo.processInfo.hostName else { return nil }
                return localFile(url.path)
            }
            // File locations such as README.md:12 are paths, not URL schemes.
            if ["http", "https", "mailto", "ftp", "ssh", "git", "tel", "magnet", "ipfs", "ipns", "gemini", "gopher", "news"].contains(scheme) { return url }
            return localFile(link)
        }
        if let file = localFile(link) { return file }
        if let decoded = link.removingPercentEncoding, decoded != link { return localFile(decoded) }
        return nil
    }
}

@MainActor
final class AppTerminalView: LocalProcessTerminalView {
    var linkDirectory = "/"
    var onLinkFailure: ((String) -> Void)?
    var linkOpener: (URL) -> Bool = { NSWorkspace.shared.open($0) }

    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = TerminalLink.resolve(link, directory: linkDirectory) else {
            onLinkFailure?(L10n.text("无法打开链接：文件不存在或链接不受支持。%@", link))
            return
        }
        if !linkOpener(url) { onLinkFailure?(L10n.text("未能打开链接，请检查默认打开应用。%@", link)) }
    }
}
