import Darwin
import Foundation

public struct ProcessIdentity: Equatable, Sendable {
    public var pid: pid_t
    public var ppid: pid_t
    public var pgid: pid_t
    public var sid: pid_t
    public var startToken: String
    public var command: String

    public init(pid: pid_t, ppid: pid_t, pgid: pid_t, sid: pid_t, startToken: String, command: String) {
        self.pid = pid
        self.ppid = ppid
        self.pgid = pgid
        self.sid = sid
        self.startToken = startToken
        self.command = command
    }

    public var isSignalable: Bool {
        pid > 1 && pgid > 1
    }
}

public struct ReaperResult: Sendable, Equatable {
    public var requested: [pid_t]
    public var remaining: [pid_t]
    public var skipped: [pid_t]
    public var timedOut: Bool

    public init(requested: [pid_t], remaining: [pid_t], skipped: [pid_t], timedOut: Bool) {
        self.requested = requested
        self.remaining = remaining
        self.skipped = skipped
        self.timedOut = timedOut
    }
}

public enum ProcessSnapshot {
    public static func list() throws -> [ProcessIdentity] {
        let output = try run(["/bin/ps", "-axo", "pid=,ppid=,pgid=,sess=,lstart=,command="])
        var identities: [ProcessIdentity] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            if let identity = parse(String(line)) {
                identities.append(identity)
            }
        }
        return identities
    }

    public static func tree(root: pid_t, from identities: [ProcessIdentity]? = nil) throws -> [ProcessIdentity] {
        let all = try identities ?? list()
        var children: [pid_t: [ProcessIdentity]] = [:]
        var byPID: [pid_t: ProcessIdentity] = [:]
        for identity in all {
            byPID[identity.pid] = identity
            children[identity.ppid, default: []].append(identity)
        }
        guard let rootIdentity = byPID[root] else { return [] }
        var ordered: [ProcessIdentity] = []
        var stack = [rootIdentity]
        var seen = Set<pid_t>()
        while let current = stack.popLast() {
            if seen.contains(current.pid) { continue }
            seen.insert(current.pid)
            ordered.append(current)
            stack.append(contentsOf: children[current.pid] ?? [])
        }
        return ordered
    }

    public static func stillMatches(_ identity: ProcessIdentity, from identities: [ProcessIdentity]) -> Bool {
        identities.contains { $0.pid == identity.pid && $0.startToken == identity.startToken }
    }

    private static func parse(_ line: String) -> ProcessIdentity? {
        let parts = line.split(whereSeparator: { $0.isWhitespace })
        guard parts.count >= 9 else { return nil }
        guard let pid = pid_t(parts[0]), let ppid = pid_t(parts[1]), let pgid = pid_t(parts[2]), let sid = pid_t(parts[3]) else {
            return nil
        }
        // lstart is 5 tokens: Weekday Month Day HH:MM:SS Year
        let startToken = parts[4...8].joined(separator: " ")
        let command = parts[9...].joined(separator: " ")
        return ProcessIdentity(pid: pid, ppid: ppid, pgid: pgid, sid: sid, startToken: startToken, command: command)
    }

    private static func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

public enum ProcessReaper {
    public static func reap(
        root: pid_t,
        exclude: Set<pid_t> = [],
        waitSeconds: TimeInterval = 1.5,
        escalateAfter: TimeInterval = 0.4
    ) throws -> ReaperResult {
        try reap(roots: [root], exclude: exclude, waitSeconds: waitSeconds, escalateAfter: escalateAfter)
    }

    public static func reap(
        roots: [pid_t],
        exclude: Set<pid_t> = [],
        waitSeconds: TimeInterval = 1.5,
        escalateAfter: TimeInterval = 0.4
    ) throws -> ReaperResult {
        let snapshot = try ProcessSnapshot.list()
        var seen = Set<pid_t>()
        let owned = try roots.flatMap { try ProcessSnapshot.tree(root: $0, from: snapshot) }
            .filter { $0.isSignalable && !exclude.contains($0.pid) && seen.insert($0.pid).inserted }
        guard !owned.isEmpty else {
            return ReaperResult(requested: [], remaining: [], skipped: [], timedOut: false)
        }
        let selfPID = getpid()
        let selfPGID = getpgrp()
        var skipped: [pid_t] = []
        var requested: [pid_t] = []
        var groups = Set<pid_t>()
        var singles = Set<pid_t>()
        for identity in owned {
            if identity.pid <= 1 || identity.pid == selfPID || exclude.contains(identity.pid) {
                skipped.append(identity.pid)
                continue
            }
            requested.append(identity.pid)
            if identity.pgid <= 1 || identity.pgid == selfPGID || identity.pgid == selfPID {
                singles.insert(identity.pid)
            } else {
                groups.insert(identity.pgid)
            }
        }

        signalTargets(groups: groups, singles: singles, signal: SIGTERM)
        Thread.sleep(forTimeInterval: escalateAfter)

        let afterTerm = try ProcessSnapshot.list()
        var stillLive = owned.filter { ProcessSnapshot.stillMatches($0, from: afterTerm) && !exclude.contains($0.pid) }
        if !stillLive.isEmpty {
            var liveGroups = Set<pid_t>()
            var liveSingles = Set<pid_t>()
            for identity in stillLive {
                if identity.pgid <= 1 || identity.pgid == selfPGID || identity.pgid == selfPID {
                    liveSingles.insert(identity.pid)
                } else {
                    liveGroups.insert(identity.pgid)
                }
            }
            signalTargets(groups: liveGroups, singles: liveSingles, signal: SIGKILL)
            Thread.sleep(forTimeInterval: max(0.2, waitSeconds - escalateAfter))
            let afterKill = try ProcessSnapshot.list()
            stillLive = owned.filter { ProcessSnapshot.stillMatches($0, from: afterKill) && !exclude.contains($0.pid) }
        }

        return ReaperResult(
            requested: requested,
            remaining: stillLive.map(\.pid),
            skipped: skipped,
            timedOut: !stillLive.isEmpty
        )
    }

    private static func signalTargets(groups: Set<pid_t>, singles: Set<pid_t>, signal: Int32) {
        for group in groups where group > 1 && group != getpgrp() && group != getpid() {
            kill(-group, signal)
        }
        for pid in singles where pid > 1 && pid != getpid() {
            kill(pid, signal)
        }
    }
}
