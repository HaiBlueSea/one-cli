import Darwin
import Foundation

public enum EventClient {
    public static let defaultTimeoutMs = 200
    public static let maxMessageBytes = 32 * 1024

    public static func send(_ envelope: EventEnvelope, socketPath: String, timeoutMs: Int = defaultTimeoutMs) -> Bool {
        guard let data = try? envelope.encoded(), data.count <= maxMessageBytes else {
            return false
        }
        return send(data: data, socketPath: socketPath, timeoutMs: timeoutMs)
    }

    public static func send(data: Data, socketPath: String, timeoutMs: Int = defaultTimeoutMs) -> Bool {
        guard socketPath.utf8.count < 104, data.count <= maxMessageBytes else {
            return false
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            for (index, byte) in pathBytes.enumerated() where index < buffer.count - 1 {
                base[index] = CChar(bitPattern: byte)
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connectResult != 0 && errno != EINPROGRESS && errno != EAGAIN {
            return false
        }

        var pollFd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let pollResult = poll(&pollFd, 1, Int32(timeoutMs))
        guard pollResult > 0 else { return false }

        var soError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &length)
        guard soError == 0 else { return false }

        return data.withUnsafeBytes { buffer in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return false }
            var sent = 0
            let deadline = DispatchTime.now() + .milliseconds(timeoutMs)
            while sent < data.count {
                if DispatchTime.now() > deadline {
                    return false
                }
                let result = Darwin.send(fd, base + sent, data.count - sent, 0)
                if result > 0 {
                    sent += result
                    continue
                }
                if result < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    var writePoll = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    if poll(&writePoll, 1, 20) <= 0 {
                        return false
                    }
                    continue
                }
                return false
            }
            return true
        }
    }
}
