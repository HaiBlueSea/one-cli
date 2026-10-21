import CryptoKit
import Darwin
import Foundation

/// Local-only, bounded WebSocket transport for Codex's owned Unix socket.
/// Network.framework aborts before its HTTP handshake on this Unix transport.
final class LocalWebSocket: @unchecked Sendable {
    enum Failure: Error { case closed, invalidProtocol, oversized }
    private let destination: URL
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var cancelled = false
    private var aliasDirectory: URL?
    private static let limit = 1_048_576

    init(destination: URL) { self.destination = destination }

    func connect() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aie-ws-" + UUID().uuidString.prefix(12))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        aliasDirectory = directory
        let alias = directory.appendingPathComponent("s")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: destination)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = Array(alias.path.utf8)
        guard path.count < MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.oversized }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            for (index, byte) in path.enumerated() { bytes[index] = byte }
        }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.closed }
        lock.withLock { fd = descriptor }
        guard !lock.withLock({ cancelled }) else { throw Failure.closed }
        var yes: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var receiveTimeout = timeval(tv_sec: 3, tv_usec: 0)
        var sendTimeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { throw Failure.closed }
        let key = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
        try write(Data("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n".utf8))
        var header = Data()
        while !header.suffix(4).elementsEqual([13, 10, 13, 10]) {
            guard header.count < 8192 else { throw Failure.oversized }
            header.append(try read(1))
        }
        let lines = String(decoding: header, as: UTF8.self).components(separatedBy: "\r\n")
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        guard lines.first?.split(separator: " ").dropFirst().first == "101",
              lines.contains(where: { line in
                  let parts = line.split(separator: ":", maxSplits: 1)
                  return parts.count == 2 && parts[0].lowercased() == "sec-websocket-accept" && parts[1].trimmingCharacters(in: .whitespaces) == accept
              }) else { throw Failure.invalidProtocol }
        // Block on events, with no periodic socket/CLI polling after startup.
        receiveTimeout = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
    }

    func sendJSON(_ object: [String: Any]) throws {
        try send(try JSONSerialization.data(withJSONObject: object), opcode: 1)
    }

    private func send(_ data: Data, opcode: UInt8) throws {
        guard data.count <= Self.limit else { throw Failure.oversized }
        var frame = Data([0x80 | opcode])
        if data.count < 126 { frame.append(0x80 | UInt8(data.count)) }
        else if data.count <= 65535 {
            frame.append(0x80 | 126)
            frame.append(UInt8(data.count >> 8)); frame.append(UInt8(data.count & 255))
        } else {
            frame.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((UInt64(data.count) >> shift) & 255)) }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: .min ... .max) }
        frame.append(contentsOf: mask)
        frame.append(contentsOf: data.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        try write(frame)
    }

    func receiveJSON() throws -> [String: Any] {
        var message = Data()
        var fragmented = false
        while true {
            let header = [UInt8](try read(2))
            let opcode = header[0] & 15
            let final = header[0] & 0x80 != 0
            guard header[0] & 0x70 == 0, header[1] & 0x80 == 0 else { throw Failure.invalidProtocol }
            var length = UInt64(header[1] & 127)
            if length == 126 { length = try read(2).reduce(0) { ($0 << 8) | UInt64($1) } }
            else if length == 127 { length = try read(8).reduce(0) { ($0 << 8) | UInt64($1) } }
            guard length <= Self.limit, message.count + Int(length) <= Self.limit else { throw Failure.oversized }
            if opcode >= 8 {
                guard final, length <= 125 else { throw Failure.invalidProtocol }
                let payload = try read(Int(length))
                if opcode == 8 { throw Failure.closed }
                if opcode == 9 { try send(payload, opcode: 10) }
                else if opcode != 10 { throw Failure.invalidProtocol }
                continue
            }
            guard (opcode == 1 && !fragmented) || (opcode == 0 && fragmented) else { throw Failure.invalidProtocol }
            message.append(try read(Int(length)))
            if final {
                guard let object = try JSONSerialization.jsonObject(with: message) as? [String: Any] else { throw Failure.invalidProtocol }
                return object
            }
            fragmented = true
        }
    }

    private func read(_ count: Int) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let descriptor = lock.withLock { cancelled ? -1 : fd }
            guard descriptor >= 0 else { throw Failure.closed }
            let received = data.withUnsafeMutableBytes { bytes in Darwin.recv(descriptor, bytes.baseAddress!.advanced(by: offset), count - offset, 0) }
            if received < 0, errno == EINTR { continue }
            guard received > 0 else { throw Failure.closed }
            offset += received
        }
        return data
    }

    private func write(_ data: Data) throws {
        var offset = 0
        while offset < data.count {
            let descriptor = lock.withLock { cancelled ? -1 : fd }
            guard descriptor >= 0 else { throw Failure.closed }
            let sent = data.withUnsafeBytes { bytes in Darwin.send(descriptor, bytes.baseAddress!.advanced(by: offset), data.count - offset, 0) }
            if sent < 0, errno == EINTR { continue }
            guard sent > 0 else { throw Failure.closed }
            offset += sent
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            if fd >= 0 { shutdown(fd, SHUT_RDWR) }
        }
    }

    func finish() {
        lock.withLock {
            cancelled = true
            if fd >= 0 { Darwin.close(fd); fd = -1 }
        }
        if let aliasDirectory {
            try? FileManager.default.removeItem(at: aliasDirectory)
            self.aliasDirectory = nil
        }
    }
}
