import Foundation
import Network
import Darwin

/// A bidirectional byte stream. The transfer protocol (handshake, framing, encryption)
/// runs unchanged on top of this, so we can swap the underlying transport — POSIX/BSD
/// sockets (kernel routing, works through a VPN like `nc`) or Network.framework — and
/// pick whichever actually reaches a given peer.
protocol ByteStream: AnyObject, Sendable {
    /// Establish the connection (NW: await `.ready`; POSIX accepted sockets: no-op).
    func open() async throws
    /// Write all of `data`.
    func sendBytes(_ data: Data) async throws
    /// Return between 1 and `max` bytes, or throw `LinkError.closed` at EOF.
    func receiveBytes(max: Int) async throws -> Data
    /// Set a receive idle timeout in seconds (0 = block indefinitely). Used to reap
    /// stalled pre-handshake connections; a no-op for event-driven transports.
    func setReadTimeout(_ seconds: TimeInterval)
    /// Tear down the stream (also unblocks any in-flight receive).
    func close()
}

/// Largest single frame we will allocate for / accept (matches the old NWConnection cap).
let kMaxFrameSize = 16 * 1024 * 1024

/// Cap on a single recv allocation, so a large frame doesn't allocate its full size on
/// every partial read. `receiveExact` loops, so correctness is unaffected.
private let kMaxReadChunk = 256 * 1024

extension ByteStream {
    /// Read exactly `count` bytes (looping over partial reads) or throw at EOF.
    func receiveExact(_ count: Int) async throws -> Data {
        if count == 0 { return Data() }
        var buffer = Data(); buffer.reserveCapacity(count)
        while buffer.count < count {
            let chunk = try await receiveBytes(max: count - buffer.count)
            if chunk.isEmpty { throw LinkError.closed }
            buffer.append(chunk)
        }
        return buffer
    }

    func sendFrame(_ data: Data) async throws {
        var length = UInt32(data.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(data)
        try await sendBytes(frame)
    }

    /// Read one length-prefixed frame, rejecting any prefix larger than `maxBytes`
    /// (defends against a hostile length forcing a huge allocation).
    func receiveFrame(maxBytes: Int = kMaxFrameSize) async throws -> Data {
        let header = try await receiveExact(4)
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian
        guard length <= maxBytes else { throw LinkError.malformed }
        return try await receiveExact(Int(length))
    }
}

// MARK: - Network.framework transport

/// A `ByteStream` backed by an `NWConnection` (Apple's stack). Used both for outbound
/// strategies and for connections accepted by the NWListener fallback.
final class NWByteStream: ByteStream, @unchecked Sendable {
    let connection: NWConnection
    init(_ connection: NWConnection) { self.connection = connection }

    func open() async throws { try await connection.startAndWaitReady() }

    func sendBytes(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    func receiveBytes(max: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, _, error in
                if let error { cont.resume(throwing: error); return }
                if let data, !data.isEmpty { cont.resume(returning: data); return }
                cont.resume(throwing: LinkError.closed)
            }
        }
    }

    func setReadTimeout(_ seconds: TimeInterval) { /* NW is event-driven; no thread to reap */ }

    func close() { connection.cancel() }
}

// MARK: - POSIX / BSD socket transport

/// A `ByteStream` backed by a raw POSIX TCP socket. This uses the kernel routing table
/// (a same-subnet peer is reached over the physical LAN interface) exactly like `nc`,
/// which is why it succeeds when one side has a VPN up and Network.framework does not.
final class POSIXByteStream: ByteStream, @unchecked Sendable {
    private let fd: Int32
    private let readQueue = DispatchQueue(label: "netcatch.posix.read")
    private let writeQueue = DispatchQueue(label: "netcatch.posix.write")
    private let closeLock = NSLock()
    private var isClosed = false
    private var closeHook: (() -> Void)?

    init(fd: Int32) {
        self.fd = fd
        // Disable Nagle: input/control events are tiny and latency-sensitive; without
        // this they're batched and delivered in bursts, making the remote pointer rough.
        // (No-op / harmless on non-TCP sockets like the test socketpair.)
        var on: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Run `hook` exactly once when the stream is closed (used to release a slot in the
    /// inbound connection limiter).
    func setOnClose(_ hook: @escaping () -> Void) {
        closeLock.lock(); defer { closeLock.unlock() }
        if isClosed { hook() } else { closeHook = hook }
    }

    private var closed: Bool { closeLock.lock(); defer { closeLock.unlock() }; return isClosed }

    func open() async throws { /* already connected/accepted */ }

    func setReadTimeout(_ seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    func sendBytes(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            writeQueue.async { [fd] in
                guard !self.closed else { cont.resume(throwing: LinkError.closed); return }
                let ok = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
                    guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return true }
                    var sent = 0
                    while sent < data.count {
                        let n = Darwin.send(fd, base + sent, data.count - sent, 0)
                        if n <= 0 { return false }
                        sent += n
                    }
                    return true
                }
                ok ? cont.resume() : cont.resume(throwing: LinkError.closed)
            }
        }
    }

    /// Synchronous framed write on the calling thread — used by the latency-sensitive
    /// control path to avoid the async send-task scheduling that batches input frames.
    func sendFrameSync(_ data: Data) -> Bool {
        if closed { return false }
        var length = UInt32(data.count).bigEndian
        var frame = Data(bytes: &length, count: 4); frame.append(data)
        return frame.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return true }
            var sent = 0
            while sent < frame.count {
                let n = Darwin.send(fd, base + sent, frame.count - sent, 0)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    func receiveBytes(max: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            readQueue.async { [fd] in
                guard !self.closed else { cont.resume(throwing: LinkError.closed); return }
                let want = Swift.min(max, kMaxReadChunk)
                var tmp = [UInt8](repeating: 0, count: want)
                let n = tmp.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, want, 0) }
                if n > 0 { cont.resume(returning: Data(tmp[0..<n])) }
                else { cont.resume(throwing: LinkError.closed) }
            }
        }
    }

    func close() {
        let hook: (() -> Void)?
        closeLock.lock()
        if isClosed { closeLock.unlock(); return }
        isClosed = true
        hook = closeHook; closeHook = nil
        closeLock.unlock()
        shutdown(fd, SHUT_RDWR)   // unblock any in-flight recv
        Darwin.close(fd)
        hook?()
    }

    // MARK: Connect / listen helpers

    /// Connect a POSIX TCP socket to `host:port` (kernel-routed, like `nc`) with a bounded
    /// non-blocking connect timeout. `host` may be an IPv4/IPv6 literal or a DNS name.
    static func connect(host: String, port: UInt16, timeout: TimeInterval) throws -> POSIXByteStream {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil,
                             ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let info = res else {
            throw LinkError.closed
        }
        defer { freeaddrinfo(res) }

        var lastErrno: Int32 = ECONNREFUSED
        var cursor: UnsafeMutablePointer<addrinfo>? = info
        while let ai = cursor {
            defer { cursor = ai.pointee.ai_next }
            let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            if fd < 0 { lastErrno = errno; continue }
            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            let r = Darwin.connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen)
            if r == 0 || errno == EISCONN {
                _ = fcntl(fd, F_SETFL, flags)
                return POSIXByteStream(fd: fd)
            }
            if errno != EINPROGRESS { lastErrno = errno; Darwin.close(fd); continue }

            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ms = Int32(timeout * 1000)
            let p = poll(&pfd, 1, ms)
            if p <= 0 { lastErrno = (p == 0) ? ETIMEDOUT : errno; Darwin.close(fd); continue }
            var soErr: Int32 = 0; var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
            if soErr != 0 { lastErrno = soErr; Darwin.close(fd); continue }
            _ = fcntl(fd, F_SETFL, flags)   // back to blocking for the transfer
            return POSIXByteStream(fd: fd)
        }
        DebugLog.log("posix connect failed → \(host):\(port) errno=\(lastErrno)", .warn)
        throw LinkError.closed
    }
}

/// Caps the number of concurrent inbound connections being handled, so a flood of
/// unauthenticated connections can't exhaust threads / CPU. Sendable so the accept loop
/// (background thread) and stream teardown can use it without actor hops.
final class InboundLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let maximum: Int
    init(maximum: Int) { self.maximum = maximum }

    /// Reserve a slot; returns false if at capacity (caller should drop the connection).
    func tryAcquire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard count < maximum else { return false }
        count += 1
        return true
    }

    func release() {
        lock.lock(); defer { lock.unlock() }
        if count > 0 { count -= 1 }
    }
}
