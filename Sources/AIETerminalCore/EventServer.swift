import Darwin
import Foundation

public final class EventServer: @unchecked Sendable {
    public struct Statistics: Sendable {
        public var accepted = 0
        public var rejected = 0
        public var decoded = 0
        public var invalid = 0
    }

    public let socketPath: String
    private let identity: AppIdentity
    private let queue = DispatchQueue(label: "com.aiterminal.events")
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private var handler: ((EventEnvelope) -> Void)?
    public private(set) var statistics = Statistics()
    private let maxMessageBytes: Int

    public init(identity: AppIdentity, socketPath: String, maxMessageBytes: Int = EventClient.maxMessageBytes) {
        self.identity = identity
        self.socketPath = socketPath
        self.maxMessageBytes = maxMessageBytes
    }

    public func start(handler: @escaping (EventEnvelope) -> Void) throws {
        self.handler = handler
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: socketPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "socket"])
        }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG))
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            for (index, byte) in pathBytes.enumerated() {
                base[index] = CChar(bitPattern: byte)
            }
        }
        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: "bind/listen"])
        }
        chmod(socketPath, S_IRUSR | S_IWUSR)
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptOne()
        }
        source.setCancelHandler {
            close(fd)
        }
        self.source = source
        source.resume()
    }

    public func stop() {
        source?.cancel()
        source = nil
        listenFD = -1
        unlink(socketPath)
    }

    private func acceptOne() {
        var addr = sockaddr_un()
        var length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let client = withUnsafeMutablePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                accept(listenFD, $0, &length)
            }
        }
        guard client >= 0 else { return }
        defer { close(client) }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let deadline = ProcessInfo.processInfo.systemUptime + 1

        var uid: uid_t = 0
        var gid: gid_t = 0
        if getpeereid(client, &uid, &gid) != 0 || uid != getuid() {
            statistics.rejected += 1
            return
        }
        statistics.accepted += 1

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while buffer.count < maxMessageBytes {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                statistics.invalid += 1
                return
            }
            let count = recv(client, &chunk, chunk.count, 0)
            if count == 0 {
                break
            }
            if count < 0 {
                if errno == EINTR { continue }
                return
            }
            buffer.append(contentsOf: chunk.prefix(count))
        }
        guard !buffer.isEmpty, buffer.count <= maxMessageBytes else {
            statistics.invalid += 1
            return
        }
        if buffer.last == 0x0A {
            buffer.removeLast()
        }
        do {
            let envelope = try EventEnvelope.decode(buffer)
            guard EventValidation.accept(envelope, identity: identity, sessionID: nil, ptyGeneration: nil) else {
                statistics.invalid += 1
                return
            }
            statistics.decoded += 1
            handler?(envelope)
        } catch {
            statistics.invalid += 1
        }
    }
}
