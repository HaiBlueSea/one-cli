import Darwin
import Foundation

/// Claude Code writes `~/.claude/sessions/<pid>.json` with `idle`, `busy`, or `waiting`.
/// A finished turn updates that file even when the Stop hook does not reach the app.
public enum ClaudeSessionStatus: Sendable {
    public static func activityState(for status: String) -> String? {
        switch status {
        case "idle": "idle"
        case "busy", "shell", "working", "running": "working"
        case "waiting": "needsInput"
        default: nil
        }
    }

    public static func activityState(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = object["status"] as? String else { return nil }
        return activityState(for: status)
    }

    public static func file(pid: pid_t, directory: URL) -> URL {
        directory.appendingPathComponent("\(pid).json")
    }

    public static func owningPID(
        startingAt pid: pid_t,
        directory: URL,
        parent: (pid_t) -> pid_t? = systemParentPID
    ) -> pid_t? {
        var current: pid_t? = pid
        for _ in 0..<8 {
            guard let pid = current, pid > 1 else { return nil }
            if FileManager.default.fileExists(atPath: file(pid: pid, directory: directory).path) {
                return pid
            }
            let next = parent(pid)
            current = next == pid ? nil : next
        }
        return nil
    }

    public static func systemParentPID(_ pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }

    public static var defaultDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".claude/sessions", isDirectory: true)
    }
}
