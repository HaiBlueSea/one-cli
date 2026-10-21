import AIETerminalRemoteCore
import Darwin
import Foundation

@main
enum RemoteHelperMain {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let args = Array(CommandLine.arguments.dropFirst())
        guard let socket = flag("socket", in: args),
              let token = flag("token", in: args),
              let portText = flag("port", in: args),
              let port = UInt16(portText),
              let root = flag("root", in: args) else {
            fputs("usage: AIERemoteHelper --socket PATH --token TOKEN --port N --root DIR\n", stderr)
            exit(2)
        }
        do {
            try Helper(
                socket: socket,
                token: token,
                port: port,
                root: root,
                extraHost: flag("allow-host", in: args)
            ).serve()
        } catch {
            fputs("helper-error\n", stderr)
            exit(1)
        }
    }
}

private func flag(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: "--" + name), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

private final class Helper: @unchecked Sendable {
    let socketPath: String
    let token: String
    let port: UInt16
    let root: String
    let allowedHost: String
    let allowedOrigin: String
    let allowedLocalHost: String
    let allowedLocalOrigin: String
    let extraHost: String?
    var ipc: Int32 = -1
    private let ipcSlot = DispatchSemaphore(value: 1)
    private let connectionSlots = DispatchSemaphore(value: 16)

    init(socket: String, token: String, port: UInt16, root: String, extraHost: String?) {
        socketPath = socket
        self.token = token
        self.port = port
        self.root = root
        allowedHost = "127.0.0.1:\(port)"
        allowedOrigin = "http://127.0.0.1:\(port)"
        allowedLocalHost = "localhost:\(port)"
        allowedLocalOrigin = "http://localhost:\(port)"
        self.extraHost = extraHost?.lowercased()
    }

    func hostAllowed(_ host: String?) -> Bool {
        guard let raw = host?.lowercased(), !raw.isEmpty else { return false }
        if raw == allowedHost || raw == allowedLocalHost { return true }
        if let extraHost, raw == extraHost || raw == extraHost + ":443" { return true }
        let name = raw.split(separator: ":").first.map(String.init) ?? raw
        return extraHost == name
    }

    func originAllowed(_ origin: String?, method: String = "GET") -> Bool {
        if origin == nil || origin?.isEmpty == true {
            return method == "GET" || method == "HEAD"
        }
        let origin = origin!
        if origin == allowedOrigin || origin == allowedLocalOrigin { return true }
        guard let extraHost else { return false }
        return origin == "https://\(extraHost)" || origin == "http://\(extraHost)"
    }

    func publicCookieHost(_ host: String?) -> Bool {
        guard let extraHost, let raw = host?.lowercased() else { return false }
        let name = raw.split(separator: ":").first.map(String.init) ?? raw
        return name == extraHost
    }

    func serve() throws {
        ipc = try connectUnix(path: socketPath)
        try writeJSON(["v": 1, "type": "hello", "token": token])
        let hello = try readJSON()
        guard hello["type"] as? String == "hello-ok" else { throw RemoteError.unauthorized }
        let parent = getppid()
        DispatchQueue.global(qos: .utility).async {
            while getppid() == parent {
                sleep(1)
            }
            exit(0)
        }
        let listenFD = try bindLoopback(port: port)
        FileHandle.standardOutput.write(Data("helper-ready port=\(port)\n".utf8))
        fflush(stdout)
        while true {
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            var addr = sockaddr_in()
            let client = withUnsafeMutablePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(listenFD, $0, &length)
                }
            }
            guard client >= 0 else { continue }
            guard connectionSlots.wait(timeout: .now()) == .success else {
                close(client)
                continue
            }
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let lifetime = HTTPConnection(client)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) {
                    lifetime.expire()
                }
                defer {
                    lifetime.finish()
                    connectionSlots.signal()
                }
                handle(client)
            }
        }
    }

    func handle(_ client: Int32) {
        do {
            let request = try readHTTP(client)
            if request.path == "/health" {
                try writeHTTP(client, 200, "application/json", Data(#"{"ok":true}"#.utf8))
                return
            }
            if let name = staticName(request.path) {
                let file = URL(fileURLWithPath: root).appendingPathComponent(name)
                let body = try Data(contentsOf: file)
                let type = name.hasSuffix(".js") ? "text/javascript; charset=utf-8"
                    : name.hasSuffix(".css") ? "text/css; charset=utf-8"
                    : "text/html; charset=utf-8"
                try writeHTTP(client, 200, type, body)
                return
            }
            // One complete IPC exchange at a time; HTTP reads never hold this lock.
            guard ipcSlot.wait(timeout: .now() + 8) == .success else { throw RemoteError.limited }
            defer { ipcSlot.signal() }
            if request.path.hasPrefix("/api/") || request.path.hasPrefix("/pair") {
                if !hostAllowed(request.host) {
                    try writeHTTP(client, 403, "text/plain", Data("host\n".utf8))
                    return
                }
                if !originAllowed(request.origin, method: request.method) {
                    try writeHTTP(client, 403, "text/plain", Data("origin\n".utf8))
                    return
                }
            }
            if request.path == "/pair" && request.method == "POST" {
                let body = try remoteObject(request.body)
                try writeJSON(["v": 1, "type": "pair", "challenge": body["challenge"] as? String ?? ""])
                let reply = try readJSON()
                var headers: [String: String] = [:]
                var payload = reply
                if let token = reply["token"] as? String {
                    var cookie = "aie_remote=\(token); Path=/; HttpOnly; SameSite=Lax; Max-Age=604800"
                    if publicCookieHost(request.host) { cookie += "; Secure" }
                    headers["Set-Cookie"] = cookie
                    payload.removeValue(forKey: "token")
                }
                try writeHTTP(client, payload["status"] as? String == "ready" ? 200 : 202, "application/json", try remoteJSON(payload), extra: headers)
                return
            }
            if routePath(request.path) == "/api/input" {
                let cookie = cookieValue(request.headers["cookie"], "aie_remote")
                guard let cookie, !cookie.isEmpty else {
                    try writeHTTP(client, 403, "application/json", Data(#"{"error":"readonly"}"#.utf8))
                    return
                }
                if request.method == "GET" {
                    try writeJSON(["v": 1, "type": "input-status", "token": cookie, "requestId": queryValue(request.path, "requestId") ?? ""])
                    try writeAuthorized(client, try readJSON())
                    return
                }
                guard request.method == "POST" else {
                    try writeHTTP(client, 405, "text/plain", Data("method\n".utf8))
                    return
                }
                let body = (try? remoteObject(request.body)) ?? [:]
                try writeJSON([
                    "v": 1,
                    "type": "input",
                    "token": cookie,
                    "requestId": body["requestId"] as? String ?? "",
                    "leaseId": body["leaseId"] as? String ?? "",
                    "sessionId": body["sessionId"] as? String ?? "",
                    "kind": body["kind"] as? String ?? "text",
                    "text": body["text"] as? String ?? "",
                    "key": body["key"] as? String ?? "",
                    "modifiers": body["modifiers"] as? Int ?? 0,
                    "enter": body["enter"] as? Bool ?? false
                ])
                try writeAuthorized(client, try readJSON())
                return
            }
            let cookie = cookieValue(request.headers["cookie"], "aie_remote")
            guard let cookie, !cookie.isEmpty else {
                try writeHTTP(client, 401, "text/plain", Data("auth\n".utf8))
                return
            }
            if request.path == "/api/control" {
                let body = request.method == "POST" ? ((try? remoteObject(request.body)) ?? [:]) : [:]
                try writeJSON([
                    "v": 1,
                    "type": "control",
                    "token": cookie,
                    "sessionId": body["sessionId"] as? String ?? queryValue(request.path, "session") ?? "",
                    "leaseId": body["leaseId"] as? String ?? "",
                    "release": body["release"] as? Bool ?? (request.method == "DELETE"),
                    "heartbeat": body["heartbeat"] as? Bool ?? false,
                    "status": request.method == "GET"
                ])
                try writeAuthorized(client, try readJSON())
                return
            }
            if request.path == "/api/sessions" {
                try writeJSON(["v": 1, "type": "sessions", "token": cookie])
                try writeAuthorized(client, try readJSON())
                return
            }
            if request.path.hasPrefix("/api/screen") {
                try writeJSON([
                    "v": 1,
                    "type": "screen",
                    "token": cookie,
                    "sessionId": queryValue(request.path, "session") ?? "",
                    "revision": queryValue(request.path, "revision") ?? "0"
                ])
                try writeAuthorized(client, try readJSON())
                return
            }
            if request.path == "/api/revoke" && request.method == "POST" {
                try writeJSON(["v": 1, "type": "revoke", "token": cookie])
                _ = try readJSON()
                try writeHTTP(client, 200, "application/json", Data(#"{"ok":true}"#.utf8), extra: [
                    "Set-Cookie": "aie_remote=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"
                ])
                return
            }
            try writeHTTP(client, 404, "text/plain", Data("missing\n".utf8))
        } catch let error as RemoteError {
            let code = error == .unauthorized || error == .expired ? 401 : 400
            try? writeHTTP(client, code, "text/plain", Data("bad\n".utf8))
        } catch {
            try? writeHTTP(client, 400, "text/plain", Data("bad\n".utf8))
        }
    }

    func writeAuthorized(_ client: Int32, _ reply: [String: Any]) throws {
        if reply["error"] as? String == "unauthorized" || reply["error"] as? String == "expired" {
            try writeHTTP(client, 401, "application/json", try remoteJSON(reply))
            return
        }
        try writeHTTP(client, 200, "application/json", try remoteJSON(reply))
    }

    func writeJSON(_ object: [String: Any]) throws {
        do {
            try writeAll(ipc, try encodeIPC(object))
        } catch {
            // A partial frame cannot be safely reused for another HTTP request.
            exit(1)
        }
    }

    func readJSON() throws -> [String: Any] {
        do {
            let header = try readExact(ipc, 4)
            let length = header.withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self).bigEndian) }
            guard length > 0, length <= RemoteLimits.ipcBytes else { throw RemoteError.limited }
            return try remoteObject(try readExact(ipc, length))
        } catch {
            exit(1)
        }
    }
}

private struct HTTPRequest {
    var method = ""
    var path = ""
    var headers: [String: String] = [:]
    var body = Data()
    var host: String? { headers["host"] }
    var origin: String? { headers["origin"] }
}

private final class HTTPConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32

    init(_ fd: Int32) { self.fd = fd }

    func expire() {
        lock.withLock {
            if fd >= 0 { shutdown(fd, SHUT_RDWR) }
        }
    }

    func finish() {
        lock.withLock {
            if fd >= 0 { close(fd) }
            fd = -1
        }
    }
}

private func readHTTP(_ fd: Int32) throws -> HTTPRequest {
    let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while data.count < RemoteLimits.headerBytes {
        let n = try readHTTPBytes(fd, &buffer, buffer.count, deadline: deadline)
        if n <= 0 { break }
        data.append(contentsOf: buffer[0..<n])
        if let range = data.range(of: Data([13, 10, 13, 10])) {
            guard range.upperBound <= RemoteLimits.headerBytes else { throw RemoteError.limited }
            let header = data.subdata(in: 0..<range.upperBound)
            var extra = data.subdata(in: range.upperBound..<data.count)
            guard let text = String(data: header, encoding: .utf8) else { throw RemoteError.rejected }
            let lines = text.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
            guard let first = lines.first else { throw RemoteError.rejected }
            let parts = first.split(separator: " ")
            guard parts.count == 3, parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else { throw RemoteError.rejected }
            var request = HTTPRequest()
            request.method = parts.isEmpty ? "" : String(parts[0])
            request.path = parts.count > 1 ? String(parts[1]) : "/"
            for line in lines.dropFirst() where !line.isEmpty {
                let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2, !pair[0].isEmpty else { throw RemoteError.rejected }
                let name = pair[0].lowercased()
                guard request.headers[name] == nil else { throw RemoteError.rejected }
                request.headers[name] = pair[1].trimmingCharacters(in: .whitespaces)
            }
            guard request.headers["transfer-encoding"] == nil else { throw RemoteError.rejected }
            let rawLength = request.headers["content-length"] ?? "0"
            guard !rawLength.isEmpty, rawLength.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let length = Int(rawLength), length >= 0 else { throw RemoteError.rejected }
            let path = parts.count > 1 ? String(parts[1]) : "/"
            let maxBody = path.hasPrefix("/api/input") ? RemoteLimits.inputMessageBytes : RemoteLimits.controlBytes
            guard length <= maxBody else { throw RemoteError.limited }
            while extra.count < length {
                let n = try readHTTPBytes(fd, &buffer, min(buffer.count, length - extra.count), deadline: deadline)
                if n <= 0 { throw RemoteError.rejected }
                extra.append(contentsOf: buffer[0..<n])
            }
            request.body = extra.prefix(length)
            return request
        }
    }
    throw RemoteError.limited
}

private func readHTTPBytes(_ fd: Int32, _ buffer: inout [UInt8], _ count: Int, deadline: UInt64) throws -> Int {
    let now = DispatchTime.now().uptimeNanoseconds
    guard now < deadline else { throw RemoteError.rejected }
    var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let remainingMS = Int32(max(1, (deadline - now) / 1_000_000))
    guard poll(&descriptor, 1, remainingMS) > 0 else { throw RemoteError.rejected }
    return read(fd, &buffer, count)
}

private func writeHTTP(_ fd: Int32, _ status: Int, _ type: String, _ body: Data, extra: [String: String] = [:]) throws {
    var header = "HTTP/1.1 \(status) OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'self'; frame-ancestors 'none'\r\nReferrer-Policy: no-referrer\r\n"
    for (key, value) in extra { header += "\(key): \(value)\r\n" }
    header += "\r\n"
    var payload = Data(header.utf8)
    payload.append(body)
    try writeAll(fd, payload)
}

private func bindLoopback(port: UInt16) throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw RemoteError.occupied }
    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bound = withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0, listen(fd, 8) == 0 else {
        close(fd)
        throw RemoteError.occupied
    }
    return fd
}

private func connectUnix(path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw RemoteError.rejected }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
        for (index, byte) in bytes.enumerated() { buffer[index] = byte }
    }
    let result = withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else {
        close(fd)
        throw RemoteError.rejected
    }
    var timeout = timeval(tv_sec: 12, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    return fd
}

private func writeAll(_ fd: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { raw in
        var sent = 0
        while sent < data.count {
            let n = Darwin.write(fd, raw.baseAddress!.advanced(by: sent), data.count - sent)
            if n <= 0 { throw RemoteError.rejected }
            sent += n
        }
    }
}

private func readExact(_ fd: Int32, _ count: Int) throws -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: min(count, 4096))
    while data.count < count {
        let n = read(fd, &buffer, min(buffer.count, count - data.count))
        if n <= 0 { throw RemoteError.rejected }
        data.append(contentsOf: buffer[0..<n])
    }
    return data
}

private func cookieValue(_ header: String?, _ name: String) -> String? {
    guard let header else { return nil }
    for part in header.split(separator: ";") {
        let pair = part.split(separator: "=", maxSplits: 1)
        if pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces) == name {
            return pair[1].trimmingCharacters(in: .whitespaces)
        }
    }
    return nil
}

private func staticName(_ path: String) -> String? {
    let name = path == "/" ? "index.html" : String(path.split(separator: "?").first?.dropFirst() ?? "")
    switch name {
    case "index.html", "app.js", "style.css", "xterm.js", "xterm.css":
        return name
    default:
        return nil
    }
}

private func routePath(_ path: String) -> String {
    String(path.split(separator: "?").first ?? Substring(path))
}

private func queryValue(_ path: String, _ name: String) -> String? {
    guard let query = path.split(separator: "?", maxSplits: 1).dropFirst().first else { return nil }
    for item in query.split(separator: "&") {
        let pair = item.split(separator: "=", maxSplits: 1)
        if pair.count == 2, pair[0] == name { return String(pair[1]) }
    }
    return nil
}
