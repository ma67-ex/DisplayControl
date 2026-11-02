import Foundation

/// Unix domain socket server: newline-delimited JSON, one request per line, owner-only (0600).
/// No TCP listener, ever (spec 5.10).
public final class IPCServer: @unchecked Sendable {
    public typealias Handler = @Sendable (IPCRequest) async -> IPCResponse

    private let path: String
    private let handler: Handler
    private var listenFD: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "app.displaycontrol.ipc.accept")
    private var source: DispatchSourceRead?

    public init(path: String = Paths.socketPath, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        unlink(path)                                    // remove a stale socket from a crash
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.system("socket", errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); throw IPCError.pathTooLong }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
            buf[bytes.count] = 0
        }
        // Make the file owner-only from the moment it exists.
        let oldMask = umask(0o177)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(oldMask)
        guard rc == 0 else { let e = errno; close(fd); throw IPCError.system("bind", e) }
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else { let e = errno; close(fd); throw IPCError.system("listen", e) }

        listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.resume()
        source = src
        Log.ipc.info("listening on \(self.path)")
    }

    public func stop() {
        source?.cancel(); source = nil
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(path)
    }

    private func acceptOne() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        var one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let handler = self.handler
        Task.detached {
            await Self.serve(client, handler)
            close(client)
        }
    }

    private static func serve(_ fd: Int32, _ handler: Handler) async {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        while true {
            // Blocking read is fine: one short-lived connection per CLI call.
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.count > 1_000_000 { return }                          // refuse absurd requests
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                var response: IPCResponse
                do {
                    let req = try decoder.decode(IPCRequest.self, from: Data(line))
                    if req.v != IPC.version {
                        response = .failure("Unsupported protocol version \(req.v) (server speaks \(IPC.version))", code: ExitCode.usage, id: req.id)
                    } else {
                        response = await handler(req)
                        response.id = req.id
                    }
                } catch {
                    response = .failure("Malformed request", code: ExitCode.usage)
                }
                var out = (try? encoder.encode(response)) ?? Data()
                out.append(0x0A)
                _ = out.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            }
        }
    }
}

public enum IPCError: Error, CustomStringConvertible {
    case system(String, Int32)
    case pathTooLong
    case notRunning
    case timeout
    case badReply

    public var description: String {
        switch self {
        case .system(let call, let e): return "\(call) failed: \(String(cString: strerror(e)))"
        case .pathTooLong: return "The socket path is too long"
        case .notRunning: return "DisplayControl is not running"
        case .timeout: return "DisplayControl did not answer in time"
        case .badReply: return "DisplayControl sent an unreadable reply"
        }
    }
}

public enum IPCClient {
    /// Sends one request and waits for one reply.
    public static func send(_ request: IPCRequest, path: String = Paths.socketPath, timeout: TimeInterval = 15) throws -> IPCResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.system("socket", errno) }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw IPCError.pathTooLong }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
            buf[bytes.count] = 0
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { throw (errno == ENOENT || errno == ECONNREFUSED) ? IPCError.notRunning : IPCError.system("connect", errno) }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var out = try JSONEncoder().encode(request)
        out.append(0x0A)
        let wrote = out.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard wrote == out.count else { throw IPCError.system("write", errno) }

        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while !data.contains(0x0A) {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 { throw (errno == EAGAIN || errno == EWOULDBLOCK) ? IPCError.timeout : IPCError.system("read", errno) }
            if n == 0 { break }
            data.append(contentsOf: chunk[0..<n])
        }
        guard let nl = data.firstIndex(of: 0x0A) else { throw IPCError.badReply }
        guard let resp = try? JSONDecoder().decode(IPCResponse.self, from: data[data.startIndex..<nl]) else { throw IPCError.badReply }
        return resp
    }
}
