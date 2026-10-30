import Foundation

/// Answers one waiting hook. Safe from any thread; only the first answer is written.
public final class PendingReply: @unchecked Sendable {
    public typealias DropHandler = @MainActor @Sendable () -> Void

    private let lock = NSLock()
    private var connection: HookServer.Connection?
    private var dropHandler: DropHandler?
    private var droppedEarly = false

    fileprivate init(_ connection: HookServer.Connection) {
        self.connection = connection
    }

    public func send(_ output: JSONValue?) {
        lock.lock()
        let target = connection
        connection = nil
        lock.unlock()
        target?.finish(with: output)
    }

    /// Runs `handler` on the main actor if the hook disconnects before it is answered (timeout or cancel),
    /// including when that already happened before the handler was set.
    public func onDrop(_ handler: @escaping DropHandler) {
        lock.lock()
        let alreadyDropped = droppedEarly
        dropHandler = alreadyDropped ? nil : handler
        lock.unlock()
        if alreadyDropped { Task { @MainActor in handler() } }
    }

    fileprivate func dropped() {
        lock.lock()
        let wasWaiting = connection != nil
        connection = nil
        let handler = dropHandler
        droppedEarly = wasWaiting && handler == nil
        lock.unlock()
        if wasWaiting, let handler { Task { @MainActor in handler() } }
    }
}

/// Listens on a unix socket for `deck-hook`. Each connection carries one newline-terminated envelope;
/// a waiting envelope keeps its connection open until it is answered or the hook goes away.
public final class HookServer: @unchecked Sendable {
    public typealias Handler = @MainActor @Sendable (HookEnvelope, PendingReply?) -> Void

    private let path: String
    private let handler: Handler
    private let log: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "agent-deck.hook-server")
    private var acceptSource: DispatchSourceRead?

    public init(path: String, log: @escaping @Sendable (String) -> Void = { _ in }, handler: @escaping Handler) {
        self.path = path
        self.log = log
        self.handler = handler
    }

    public func stop() {
        queue.sync {
            acceptSource?.cancel()
            acceptSource = nil
        }
        unlink(path)
    }

    public func start() throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { close(fd); throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 64) == 0 else {
            let error = POSIXError(.init(rawValue: errno) ?? .EIO)
            close(fd)
            throw error
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending(on: fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
    }

    private func acceptPending(on listener: Int32) {
        while true {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
                close(fd)
                continue
            }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            Connection(fd: fd, queue: queue, server: self).start()
        }
    }

    fileprivate func deliver(_ envelope: HookEnvelope, reply: PendingReply?) {
        let handler = self.handler
        Task { @MainActor in handler(envelope, reply) }
    }

    final class Connection: @unchecked Sendable {
        private static let maxEnvelope = 16 << 20

        private let fd: Int32
        private let queue: DispatchQueue
        private weak var server: HookServer?
        private var source: DispatchSourceRead?
        private var buffer = Data()
        private var pending: PendingReply?
        private var finished = false

        init(fd: Int32, queue: DispatchQueue, server: HookServer) {
            self.fd = fd
            self.queue = queue
            self.server = server
        }

        func start() {
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [self] in readAvailable() }
            source.setCancelHandler { [fd] in close(fd) }
            self.source = source
            source.resume()
        }

        private func readAvailable() {
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let count = read(fd, &chunk, chunk.count)
            if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) {
                pending?.dropped()
                return stop()
            }
            guard count > 0, pending == nil else { return }
            buffer.append(contentsOf: chunk[0..<count])
            guard let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) else {
                if buffer.count > Self.maxEnvelope { stop() }
                return
            }
            guard let envelope = try? JSONDecoder().decode(HookEnvelope.self, from: buffer[buffer.startIndex..<newline]) else {
                server?.log("hook server: unreadable envelope (\(newline) bytes)")
                return stop()
            }
            if envelope.wait {
                let reply = PendingReply(self)
                pending = reply
                server?.deliver(envelope, reply: reply)
            } else {
                server?.deliver(envelope, reply: nil)
                stop()
            }
        }

        /// Writes `{"output": …}` and closes. Called through PendingReply from any thread.
        fileprivate func finish(with output: JSONValue?) {
            queue.async { [self] in
                guard !finished else { return }
                var line = Data(#"{"output":"#.utf8)
                line.append(output?.encoded() ?? Data("null".utf8))
                line.append(Data("}\n".utf8))
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
                line.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        let written = write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                        if written <= 0 { break }
                        offset += written
                    }
                }
                stop()
            }
        }

        private func stop() {
            guard !finished else { return }
            finished = true
            source?.cancel()
            source = nil
        }
    }
}
