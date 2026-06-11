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
    /// Tear down the stream (also unblocks any in-flight receive).
    func close()
}

/// Largest single frame we will allocate for / accept (matches the old NWConnection cap).
private let kMaxFrameSize = 16 * 1024 * 1024

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

    func receiveFrame() async throws -> Data {
        let header = try await receiveExact(4)
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian
        guard length <= kMaxFrameSize else { throw LinkError.malformed }
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

    init(fd: Int32) { self.fd = fd }

    func open() async throws { /* already connected/accepted */ }

    func sendBytes(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            writeQueue.async { [fd] in
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

    func receiveBytes(max: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            readQueue.async { [fd] in
                var tmp = [UInt8](repeating: 0, count: max)
                let n = tmp.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, max, 0) }
                if n > 0 { cont.resume(returning: Data(tmp[0..<n])) }
                else { cont.resume(throwing: LinkError.closed) }
            }
        }
    }

    func close() {
        closeLock.lock(); defer { closeLock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        shutdown(fd, SHUT_RDWR)   // unblock any in-flight recv
        Darwin.close(fd)
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
