import AIETerminalCore
import Darwin
import Foundation

/// Watches one Claude session file. The existing `busy` value is remembered so a
/// later `idle` write can end the turn; a stale idle file does not cancel a prompt
/// that has just started.
final class ClaudeSessionWatch: @unchecked Sendable {
    let pid: pid_t
    private let file: URL
    private let directory: URL
    private let onState: @Sendable (String) -> Void
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var sawBusy = false

    init(pid: pid_t, directory: URL = ClaudeSessionStatus.defaultDirectory, onState: @escaping @Sendable (String) -> Void) {
        self.pid = pid
        self.directory = directory
        self.file = ClaudeSessionStatus.file(pid: pid, directory: directory)
        self.onState = onState
    }

    func start() {
        if let state = currentState(), state == "working" {
            sawBusy = true
        }
        watch(directory, mask: [.write]) { [weak self] in self?.publish() }
        watch(file, mask: [.write, .extend, .rename, .delete]) { [weak self] in self?.publish() }
    }

    func stop() {
        directorySource?.cancel()
        fileSource?.cancel()
        directorySource = nil
        fileSource = nil
    }

    private func watch(_ url: URL, mask: DispatchSource.FileSystemEvent, handler: @escaping () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
        source.setEventHandler(handler: handler)
        source.setCancelHandler { close(fd) }
        source.resume()
        if url == directory {
            directorySource = source
        } else {
            fileSource = source
        }
    }

    private func publish() {
        if fileSource == nil {
            watch(file, mask: [.write, .extend, .rename, .delete]) { [weak self] in self?.publish() }
        }
        guard let state = currentState() else { return }
        if state == "working" {
            sawBusy = true
        }
        if state == "idle" && !sawBusy {
            return
        }
        onState(state)
    }

    private func currentState() -> String? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return ClaudeSessionStatus.activityState(in: data)
    }
}
