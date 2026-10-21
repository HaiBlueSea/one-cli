import Foundation

public struct LayoutSnapshot: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var writeRevision: UInt64
    public var slots: [Slot]
    public var selectedID: String?
    public var collapsedGroups: [String]
    public var windowWidth: Double
    public var windowHeight: Double
    public var sidebarWidth: Double

    enum CodingKeys: String, CodingKey {
        case schemaVersion, writeRevision, slots, selectedID, collapsedGroups
        case windowWidth, windowHeight, sidebarWidth
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        writeRevision = try container.decodeIfPresent(UInt64.self, forKey: .writeRevision) ?? 0
        slots = try container.decode([Slot].self, forKey: .slots)
        selectedID = try container.decodeIfPresent(String.self, forKey: .selectedID)
        collapsedGroups = try container.decodeIfPresent([String].self, forKey: .collapsedGroups) ?? []
        windowWidth = try container.decodeIfPresent(Double.self, forKey: .windowWidth) ?? 1100
        windowHeight = try container.decodeIfPresent(Double.self, forKey: .windowHeight) ?? 680
        sidebarWidth = try container.decodeIfPresent(Double.self, forKey: .sidebarWidth) ?? 200
    }

    public struct Slot: Codable, Sendable, Equatable {
        public var id: String
        public var cwd: String

        public init(id: String, cwd: String) {
            self.id = id
            self.cwd = cwd
        }
    }

    public init(
        schemaVersion: Int = 1,
        writeRevision: UInt64 = 0,
        slots: [Slot],
        selectedID: String?,
        collapsedGroups: [String] = [],
        windowWidth: Double = 1100,
        windowHeight: Double = 680,
        sidebarWidth: Double = 200
    ) {
        self.schemaVersion = schemaVersion
        self.writeRevision = writeRevision
        self.slots = slots
        self.selectedID = selectedID
        self.collapsedGroups = collapsedGroups
        self.windowWidth = windowWidth
        self.windowHeight = windowHeight
        self.sidebarWidth = sidebarWidth
    }

    public func sanitized(home: String) -> (LayoutSnapshot, fellBack: Bool) {
        var seen = Set<String>()
        var fellBack = false
        let slots = slots.compactMap { slot -> Slot? in
            if slot.id.isEmpty || seen.contains(slot.id) { return nil }
            let logical = LayoutPath.normalize(slot.cwd)
            if logical.isEmpty { return nil }
            seen.insert(slot.id)
            let resolved = LayoutPath.resolveForRestore(logical, home: home)
            if resolved.fellBack { fellBack = true }
            return Slot(id: slot.id, cwd: resolved.cwd)
        }
        var copy = self
        copy.slots = slots
        copy.collapsedGroups = Set(collapsedGroups.map(LayoutPath.normalize))
            .intersection(Set(slots.map(\.cwd))).sorted()
        if let selected = copy.selectedID, !seen.contains(selected) {
            copy.selectedID = slots.first?.id
        }
        copy.windowWidth = LayoutPath.clamp(copy.windowWidth, min: 480, max: 10_000, fallback: 1100)
        copy.windowHeight = LayoutPath.clamp(copy.windowHeight, min: 320, max: 10_000, fallback: 680)
        copy.sidebarWidth = LayoutPath.clamp(copy.sidebarWidth, min: 160, max: copy.windowWidth - 320, fallback: 200)
        return (copy, fellBack)
    }
}

public enum SnapshotLoadResult: Sendable, Equatable {
    case missing
    case loaded(LayoutSnapshot)
    case corrupt
    case unsupportedSchema(Int)
}

public enum SnapshotSaveError: Error, Equatable {
    case staleRevision
}

public enum LayoutPath {
    public static func normalize(_ path: String) -> String {
        var result = path
        guard !result.isEmpty else { return result }
        while result.contains("//") {
            result = result.replacingOccurrences(of: "//", with: "/")
        }
        if result.count > 1, result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    public static func resolveForRestore(_ path: String, home: String, fileManager: FileManager = .default) -> (cwd: String, fellBack: Bool) {
        let logical = normalize(path)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: logical, isDirectory: &isDirectory),
           isDirectory.boolValue,
           fileManager.isReadableFile(atPath: logical) {
            return (logical, false)
        }
        return (normalize(home), true)
    }

    public static func clamp(_ value: Double, min: Double, max: Double, fallback: Double) -> Double {
        if value.isNaN || value.isInfinite || value < min || value > max {
            return fallback
        }
        return value
    }
}

public final class SnapshotStore: @unchecked Sendable {
    public let url: URL
    public let corruptBackupURL: URL
    private let queue = DispatchQueue(label: "com.aiterminal.snapshot")
    private var committedRevision: UInt64 = 0

    public init(url: URL) {
        self.url = url
        self.corruptBackupURL = url.deletingLastPathComponent().appendingPathComponent("layout.json.corrupt")
    }

    public convenience init(flavor: AppFlavor) throws {
        let root = try RuntimePaths.supportDirectory(flavor: flavor)
        self.init(url: root.appendingPathComponent("layout.json"))
    }

    public func load() -> SnapshotLoadResult {
        queue.sync {
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: url.path) else {
                committedRevision = 0
                return .missing
            }
            guard let data = try? Data(contentsOf: url), !data.isEmpty else {
                quarantineLocked()
                return .corrupt
            }
            guard let snapshot = try? JSONDecoder().decode(LayoutSnapshot.self, from: data) else {
                quarantineLocked()
                return .corrupt
            }
            if snapshot.schemaVersion != 1 {
                return .unsupportedSchema(snapshot.schemaVersion)
            }
            committedRevision = snapshot.writeRevision
            return .loaded(snapshot)
        }
    }

    public func save(_ snapshot: LayoutSnapshot) throws {
        try queue.sync {
            if snapshot.writeRevision < committedRevision {
                throw SnapshotSaveError.staleRevision
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let temp = url.appendingPathExtension("tmp")
            try data.write(to: temp, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: url)
            }
            committedRevision = snapshot.writeRevision
        }
    }

    private func quarantineLocked() {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.removeItem(at: corruptBackupURL)
        try? fileManager.copyItem(at: url, to: corruptBackupURL)
    }
}
