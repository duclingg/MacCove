//
//  AgentBridge.swift
//  MacCove
//
//  Created by Justin Hoang on 11/2/26.
//

import Foundation

/// A small HTTP server on a Unix socket, which the hook scripts MacCove
/// installs into Claude Code, Codex and Cursor reach with `curl
/// --unix-socket`.
///
/// A socket file rather than a port: only this user can open it, so
/// nothing else on the Mac can send it events or answer its approvals. A
/// hook asking for approval keeps its connection open until the island's
/// Allow or Deny, then gets the decision back as the response.
nonisolated final class AgentBridge: @unchecked Sendable {
    struct Request: Sendable {
        /// "/claude/PermissionRequest" and the like.
        let path: String
        let headers: [String: String]
        let body: Data
    }

    struct Response: Sendable {
        var body = Data()

        /// What a hook prints when it has nothing to say: the agent goes on
        /// as if MacCove weren't there.
        static let empty = Response()

        static func json(_ object: Any) -> Response {
            Response(body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
        }
    }

    typealias Handler = @MainActor @Sendable (Request) async -> Response

    /// In Application Support, which only this user can read. Well under the
    /// 104 bytes a socket's path may have.
    static var socketURL: URL {
        URL.applicationSupportDirectory.appending(path: "MacCove/agents.sock")
    }

    /// Anything bigger isn't from a hook.
    private static let maxRequestSize = 4 << 20
    /// For reading a request, not for the answer, which can take minutes.
    private static let readTimeout: Int = 10

    private let handler: Handler
    private var listener: Int32 = -1

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func start() throws {
        let url = Self.socketURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let path = url.path(percentEncoded: false)
        // A socket left by a copy that quit without cleaning up.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8) + [0]
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
            let error = POSIXError(.init(rawValue: errno) ?? .EIO)
            close(fd)
            throw error
        }
        listener = fd

        let thread = Thread { [weak self] in
            self?.acceptConnections(on: fd)
        }
        thread.name = "MacCove agent bridge"
        thread.start()
    }

    private func acceptConnections(on fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else {
                if errno == EINTR { continue }
                return
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.serve(client)
            }
        }
    }

    /// Reads one request, waits for the handler's answer, sends it and
    /// closes. Each hook call is its own connection.
    private func serve(_ client: Int32) {
        var timeout = timeval(tv_sec: Self.readTimeout, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        guard let request = readRequest(from: client) else {
            close(client)
            return
        }
        let handler = handler
        Task { @MainActor in
            let response = await handler(request)
            DispatchQueue.global(qos: .userInitiated).async {
                Self.write(response, to: client)
                close(client)
            }
        }
    }

    private func readRequest(from client: Int32) -> Request? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        let separator = Data("\r\n\r\n".utf8)
        var headerEnd: Range<Data.Index>?
        var contentLength = 0

        while true {
            if headerEnd == nil, let range = buffer.range(of: separator) {
                headerEnd = range
                let head = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
                contentLength = Self.headers(in: head)["content-length"].flatMap { Int($0) } ?? 0
            }
            if let headerEnd, buffer.count - headerEnd.upperBound >= contentLength {
                break
            }
            guard buffer.count < Self.maxRequestSize else { return nil }
            let count = read(client, &chunk, chunk.count)
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<count])
        }

        guard let headerEnd else { return nil }
        let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
        let requestLine = head.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let bodyStart = headerEnd.upperBound
        return Request(
            path: String(parts[1]),
            headers: Self.headers(in: head),
            body: buffer[bodyStart..<(bodyStart + contentLength)]
        )
    }

    /// Lowercased names, as HTTP's are case-insensitive.
    private static func headers(in head: String) -> [String: String] {
        var headers: [String: String] = [:]
        for line in head.split(separator: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return headers
    }

    private static func write(_ response: Response, to client: Int32) {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(response.body)
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(client, raw.baseAddress! + offset, raw.count - offset)
                guard written > 0 else { return }
                offset += written
            }
        }
    }
}
