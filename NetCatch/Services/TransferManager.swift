import Foundation
import Network

/// Where to save an accepted incoming transfer.
struct ReceiveDecision {
    var directory: URL
    var name: String
}

/// A pending incoming transfer awaiting the user's accept/reject + save choice.
@MainActor
final class IncomingRequest: ObservableObject, Identifiable {
    let id = UUID()
    let transfer: Transfer
    let header: TransferHeader
    let fingerprint: String
    let isTrusted: Bool
    let defaultDirectory: URL
    private let respond: (ReceiveDecision?) -> Void

    init(transfer: Transfer, header: TransferHeader, fingerprint: String, isTrusted: Bool,
         defaultDirectory: URL, respond: @escaping (ReceiveDecision?) -> Void) {
        self.transfer = transfer
        self.header = header
        self.fingerprint = fingerprint
        self.isTrusted = isTrusted
        self.defaultDirectory = defaultDirectory
        self.respond = respond
    }

    var suggestedName: String { header.items.first?.name ?? "received" }

    func resolve(_ decision: ReceiveDecision?) { respond(decision) }
}

/// Central coordinator: owns the services and runs the send/receive protocol.
@MainActor
final class TransferManager: ObservableObject {
    @Published var transfers: [Transfer] = []
    @Published var pendingRequest: IncomingRequest?

    let settings: AppSettings
    let history: HistoryStore
    let receiver = ReceiverServer()
    let discovery = DiscoveryService()
    let trust = TrustStore()
    let readiness = ControlReadiness()

    private let chunkSize = 256 * 1024

    /// In-flight transfer tasks and their links, keyed by transfer id, so either a
    /// send or a receive can be cancelled mid-flight.
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var activeLinks: [UUID: PeerLink] = [:]

    /// Watches for the LAN address changing (DHCP renew, Wi-Fi switch) so the listener,
    /// which binds to a specific LAN IP, can be rebound instead of going stale.
    private let pathMonitor = NWPathMonitor()
    private var pathMonitorStarted = false
    private var lastBoundIP: String?
    private var rebindTask: Task<Void, Never>?

    init(settings: AppSettings, history: HistoryStore) {
        self.settings = settings
        self.history = history
        receiver.onIncoming = { [weak self] link in
            self?.handleIncoming(link)
        }
    }

    func startServices() {
        DebugLog.log("services: starting as '\(settings.deviceName)', listen port \(settings.port)")
        discovery.ownServiceName = settings.deviceName
        receiver.start(serviceName: settings.deviceName, port: settings.port)
        lastBoundIP = LocalNetwork.ipv4Address()
        discovery.start()
        NotificationService.requestAuthorization()
        startPathMonitorIfNeeded()
    }

    func restartServices() {
        receiver.stop()
        discovery.stop()
        TransportConnector.shared.resetCache()   // network may have changed; re-probe transports
        startServices()
    }

    /// Begin watching for network-path changes (started once, lives for the app session).
    private func startPathMonitorIfNeeded() {
        guard !pathMonitorStarted else { return }
        pathMonitorStarted = true
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.handlePathChange() }
        }
        pathMonitor.start(queue: .global(qos: .utility))
    }

    /// On a network change, rebind the listener if our LAN address actually changed.
    /// Debounced, because the new address may not have settled when the path event fires.
    private func handlePathChange() {
        guard LocalNetwork.ipv4Address() != lastBoundIP else { return }
        rebindTask?.cancel()
        rebindTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self, !Task.isCancelled else { return }
            let settled = LocalNetwork.ipv4Address()
            guard settled != self.lastBoundIP else { return }
            DebugLog.log("network: LAN address changed (\(self.lastBoundIP ?? "none") → \(settled ?? "none")) — rebinding listener", .warn)
            self.restartServices()
        }
    }

    // MARK: Sending

    func send(urls: [URL], to peer: Peer, compress: Bool) {
        let transfer = Transfer(direction: .send, peerName: peer.name, items: [], totalBytes: 0)
        transfer.state = .connecting
        transfers.insert(transfer, at: 0)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runSend(transfer: transfer, urls: urls, peer: peer, compress: compress)
        }
        tasks[transfer.id] = task
    }

    /// Cancel an in-flight transfer (send or receive): tears down the connection and the
    /// task. On a send, the receiver fails on the dropped connection but keeps any partial
    /// for a later resume; on a receive, our own partial is likewise kept.
    func cancel(_ transfer: Transfer) {
        guard transfer.state.isActive else { return }
        let role = transfer.direction == .send ? "send" : "receive"
        DebugLog.log("\(role): cancel requested for '\(transfer.primaryName)' (\(transfer.peerName))", .warn)
        transfer.state = .cancelled
        transfer.finishTiming()
        activeLinks[transfer.id]?.cancel()
        tasks[transfer.id]?.cancel()
    }

    // MARK: Control (KVM) — receive injected input on the controlled Mac

    @Published var controlActiveFrom: String?   // peer name currently controlling us, if any

    private func runControlReceive(link: PeerLink) async {
        let name = link.remoteName
        controlActiveFrom = name
        DebugLog.log("control: session started from \(name)")
        // Run the decode+inject loop off the main actor so it doesn't fight the UI.
        await Task.detached(priority: .userInitiated) {
            let injector = ControlInjector()
            var moves = 0, others = 0
            var last = Date(), maxGap = 0.0, maxApply = 0.0, window = Date()
            do {
                while true {
                    let event = try await link.receiveSecureObject(ControlEvent.self)
                    if event.kind == .hostStats {
                        DebugLog.log("control host(remote): \(Int(event.dx)) moves/s sent, \(Int(event.dy)) ticks/s")
                        continue
                    }
                    let now = Date()
                    let gap = now.timeIntervalSince(last) * 1000; last = now
                    let t0 = Date(); injector.apply(event)
                    maxApply = max(maxApply, Date().timeIntervalSince(t0) * 1000)
                    if event.kind == .mouseMove { moves += 1; maxGap = max(maxGap, gap) } else { others += 1 }
                    if now.timeIntervalSince(window) >= 1.0 {
                        DebugLog.log("control recv: \(moves) moves/s (+\(others) other), arrival gap max \(String(format: "%.1f", maxGap))ms, inject max \(String(format: "%.2f", maxApply))ms")
                        moves = 0; others = 0; maxGap = 0; maxApply = 0; window = now
                    }
                }
            } catch {
                injector.releaseAll()
                DebugLog.log("control: session closed — \(error.localizedDescription)", .warn)
            }
        }.value
        controlActiveFrom = nil
        link.cancel()
        DebugLog.log("control: session ended (\(name))")
    }

    // MARK: Status exchange (readiness over the authenticated link)

    /// Open a status session to `peer` and return its readiness report (or nil on failure).
    func queryStatus(of peer: Peer) async -> StatusReport? {
        do {
            let link = try await TransportConnector.shared.connect(to: peer, localName: settings.deviceName,
                                                                   allowed: settings.enabledTransportStrategies)
            defer { link.cancel() }
            try await link.sendSecureObject(SessionHello(kind: .status))
            return try await link.receiveSecureObject(StatusReport.self)
        } catch {
            DebugLog.log("status: query to '\(peer.name)' failed — \(error.localizedDescription)", .warn)
            return nil
        }
    }

    /// This device's readiness, for replying to a status query or showing locally.
    func localStatusReport() -> StatusReport {
        readiness.refresh()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return StatusReport(deviceName: settings.deviceName,
                            appVersion: version,
                            control: readiness.allReady,
                            controlAccessibility: readiness.accessibility,
                            controlInputMonitoring: readiness.inputMonitoring,
                            controlEventTap: readiness.eventTapCreatable,
                            workbook: false)   // workbook sync not built yet
    }

    private func runSend(transfer: Transfer, urls: [URL], peer: Peer, compress: Bool) async {
        defer {
            tasks[transfer.id] = nil
            activeLinks[transfer.id] = nil
        }
        DebugLog.log("send: starting → '\(peer.name)' endpoint=\(peer.endpoint) compress=\(compress)")

        var prepared: [PreparedItem] = []
        do {
            // Source URLs from the "Choose…" panel / Finder are security-scoped: under
            // App Sandbox we must hold access while reading them to package the send,
            // otherwise the read is denied. (Held for the whole transfer.)
            let scopedSources = urls.filter { $0.startAccessingSecurityScopedResource() }
            defer { scopedSources.forEach { $0.stopAccessingSecurityScopedResource() } }

            prepared = try await Task.detached(priority: .userInitiated) {
                try urls.map { try ArchiveService.prepare(url: $0, compressRequested: compress) }
            }.value

            let header = TransferHeader(senderName: settings.deviceName, items: prepared.map(\.item))
            transfer.items = header.items
            transfer.totalBytes = header.totalTransmitted

            // Adaptively pick the transport that actually reaches this peer (raw POSIX
            // socket first — routes like netcat through a VPN — then Network.framework
            // variants), validated through the handshake and cached per peer.
            try Task.checkCancellation()
            let link = try await TransportConnector.shared.connect(to: peer, localName: settings.deviceName,
                                                                   allowed: settings.enabledTransportStrategies)
            activeLinks[transfer.id] = link
            transfer.peerName = link.remoteName == "Unknown" ? peer.name : link.remoteName
            transfer.peerFingerprint = link.remoteFingerprint
            DebugLog.log("send: connected + handshake ok, peer=\(link.remoteName) fp=\(link.remoteFingerprint)")

            try await link.sendSecureObject(SessionHello(kind: .transfer))
            try await link.sendSecureObject(header)
            DebugLog.log("send: header sent (\(header.items.count) item(s), \(header.totalTransmitted) bytes) — awaiting accept")
            let decision = try await link.receiveSecureObject(TransferDecision.self)
            DebugLog.log("send: peer accepted=\(decision.accepted)")
            guard decision.accepted else {
                transfer.state = .rejected
                link.cancel()
                cleanup(prepared)
                return
            }

            // Receiver reports how much of each item it already holds (resume).
            let resume = try await link.receiveSecureObject(ResumeInfo.self)

            transfer.state = .transferring
            for (i, item) in prepared.enumerated() {
                let from = i < resume.offsets.count ? max(0, resume.offsets[i]) : 0
                try await sendBlob(link: link, prepared: item, transfer: transfer, fromOffset: from)
            }
            // Wait for the receiver to confirm full receipt before closing, so the
            // final bytes are never dropped by an early teardown.
            _ = try await link.receiveSecureObject(TransferAck.self)
            link.cancel()
            DebugLog.log("send: complete → '\(transfer.primaryName)' to \(transfer.peerName)")
            finish(transfer, succeeded: true)
        } catch is CancellationError {
            markCancelled(transfer)
        } catch {
            // A user-requested cancel tears down the link, surfacing as a connection
            // error here — treat it as a cancellation, not a failure.
            if transfer.state == .cancelled || Task.isCancelled {
                markCancelled(transfer)
            } else {
                DebugLog.log("send: FAILED — \(error.localizedDescription) [\(error)]", .error)
                fail(transfer, error)
            }
        }
        cleanup(prepared)
    }

    private func sendBlob(link: PeerLink, prepared: PreparedItem, transfer: Transfer,
                          fromOffset: Int64 = 0) async throws {
        let handle = try FileHandle(forReadingFrom: prepared.blobURL)
        defer { try? handle.close() }
        var offset = UInt64(max(0, fromOffset))
        if offset > 0 {
            try handle.seek(toOffset: offset)
            transfer.advance(by: Int64(offset))   // count already-received bytes as done
        }
        while true {
            try Task.checkCancellation()
            let chunk = (try handle.read(upToCount: chunkSize)) ?? Data()
            if chunk.isEmpty { break }
            var beOffset = offset.bigEndian
            var frame = Data(bytes: &beOffset, count: 8)
            frame.append(chunk)
            try await link.sendSecure(frame)
            offset += UInt64(chunk.count)
            transfer.advance(by: Int64(chunk.count))
        }
    }

    // MARK: Receiving

    private func handleIncoming(_ link: PeerLink) {
        // Handshake, then branch on the session kind the initiator selected.
        Task { @MainActor [weak self] in
            guard let self else { link.cancel(); return }
            do {
                try await link.start()
                try await link.handshake(localName: self.settings.deviceName)
                let hello = try await link.receiveSecureObject(SessionHello.self)
                DebugLog.log("incoming: \(hello.kind.rawValue) session from \(link.remoteName) fp=\(link.remoteFingerprint)")
                switch hello.kind {
                case .status:
                    // Reply with our readiness over the same authenticated link; no prompt.
                    try await link.sendSecureObject(self.localStatusReport())
                    link.cancel()
                case .control:
                    let accepted = self.settings.controlEnabled
                    try await link.sendSecureObject(ControlAck(
                        accepted: accepted,
                        reason: accepted ? "" : "Control is turned off on \(self.settings.deviceName)"))
                    guard accepted else {
                        DebugLog.log("incoming: control session refused (control disabled)", .warn)
                        link.cancel(); return
                    }
                    await self.runControlReceive(link: link)
                case .transfer:
                    let transfer = Transfer(direction: .receive, peerName: link.remoteName, items: [], totalBytes: 0)
                    self.activeLinks[transfer.id] = link
                    let task = Task { [weak self] in
                        guard let self else { return }
                        await self.runReceive(transfer: transfer, link: link)
                    }
                    self.tasks[transfer.id] = task
                }
            } catch {
                DebugLog.log("incoming: failed before session start — \(error.localizedDescription)", .warn)
                link.cancel()
            }
        }
    }

    private func runReceive(transfer: Transfer, link: PeerLink) async {
        defer {
            tasks[transfer.id] = nil
            activeLinks[transfer.id] = nil
        }
        do {
            let header = try await link.receiveSecureObject(TransferHeader.self)
            DebugLog.log("receive: header (\(header.items.count) item(s), \(header.totalTransmitted) bytes) from \(header.senderName)")
            // Reject a malformed sha256 before it is ever used as a partial-file name
            // (path-traversal guard on the untrusted header).
            guard header.items.allSatisfy({ PartialStore.isValidSHA256($0.sha256) }) else {
                throw LinkError.malformed
            }

            transfer.peerName = link.remoteName
            transfer.peerFingerprint = link.remoteFingerprint
            transfer.items = header.items
            transfer.totalBytes = header.totalTransmitted
            transfer.state = .awaitingApproval
            transfers.insert(transfer, at: 0)

            let trusted = trust.isTrusted(link.remoteFingerprint)
            let decision = await requestApproval(transfer: transfer, header: header,
                                                 fingerprint: link.remoteFingerprint, trusted: trusted)
            try await link.sendSecureObject(TransferDecision(accepted: decision != nil))

            guard let decision else {
                transfer.state = .rejected
                link.cancel()
                return
            }

            trust.trust(link.remoteFingerprint, name: link.remoteName)
            // Tell the sender how much of each item we already hold, so it can resume.
            let resumeOffsets = header.items.map { item -> Int64 in
                let have = PartialStore.size(forSHA: item.sha256)
                return (have > 0 && have <= item.transmittedSize) ? have : 0
            }
            try await link.sendSecureObject(ResumeInfo(offsets: resumeOffsets))

            transfer.state = .transferring
            let location = try await receivePayload(link: link, header: header, decision: decision,
                                                    resumeOffsets: resumeOffsets, transfer: transfer)
            transfer.savedLocation = location
            // Confirm receipt, then wait for the sender to close first so the ack is
            // guaranteed flushed before we tear down our side.
            try await link.sendSecureObject(TransferAck(ok: true))
            _ = try? await link.receiveSecure()
            link.cancel()
            finish(transfer, succeeded: true)
            DebugLog.log("receive: complete → saved '\(transfer.primaryName)' from \(transfer.peerName)")
            NotificationService.notify(title: "Received from \(transfer.peerName)",
                                       body: transfer.primaryName)
        } catch is CancellationError {
            markCancelled(transfer)
            link.cancel()
        } catch {
            // A user-requested cancel tears down the link, surfacing as a connection
            // error here — treat it as a cancellation, not a failure.
            if transfer.state == .cancelled || Task.isCancelled {
                markCancelled(transfer)
            } else {
                DebugLog.log("receive: FAILED — \(error.localizedDescription) [\(error)]", .error)
                fail(transfer, error)
            }
            link.cancel()
        }
    }

    private func receivePayload(link: PeerLink, header: TransferHeader, decision: ReceiveDecision,
                               resumeOffsets: [Int64], transfer: Transfer) async throws -> URL {
        let scoped = decision.directory.startAccessingSecurityScopedResource()
        defer { if scoped { decision.directory.stopAccessingSecurityScopedResource() } }

        var firstDestination: URL?
        for (index, item) in header.items.enumerated() {
            // Persistent, content-addressed partial blob (survives interruption/restart).
            let partURL = PartialStore.url(forSHA: item.sha256)
            let resumeOffset = index < resumeOffsets.count ? resumeOffsets[index] : 0
            if resumeOffset == 0 {
                FileManager.default.createFile(atPath: partURL.path, contents: nil)  // fresh/truncate
            }
            let handle = try FileHandle(forWritingTo: partURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(resumeOffset))

            var received: Int64 = resumeOffset
            if resumeOffset > 0 { transfer.advance(by: resumeOffset) }   // already-held bytes count as done
            while received < item.transmittedSize {
                try Task.checkCancellation()
                let frame = try await link.receiveSecure()
                guard frame.count >= 8 else { throw LinkError.malformed }
                let offset = frame.prefix(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.bigEndian
                let payload = frame.dropFirst(8)
                // Require contiguous, in-bounds writes (now starting at the resume point):
                // prevents arbitrary seeks that could create a huge sparse file (DoS).
                guard offset == UInt64(received),
                      offset + UInt64(payload.count) <= UInt64(item.transmittedSize) else {
                    throw LinkError.malformed
                }
                try handle.seek(toOffset: offset)
                handle.write(Data(payload))
                received += Int64(payload.count)
                transfer.advance(by: Int64(payload.count))
            }
            try handle.close()

            transfer.state = .verifying
            let digest = try await Task.detached(priority: .userInitiated) {
                try CryptoService.sha256Hex(ofFileAt: partURL)
            }.value
            guard digest == item.sha256 else {
                PartialStore.remove(sha: item.sha256)   // corrupt — discard so a retry restarts cleanly
                throw LinkError.integrityMismatch(item.name)
            }

            let baseName = Self.sanitizedComponent(index == 0 ? decision.name : item.name)
            let target = decision.directory.appendingPathComponent(baseName)
            guard Self.isContained(target, in: decision.directory) else { throw LinkError.malformed }
            let destination = uniqueURL(target)

            let savedURL: URL
            do {
                try await Task.detached(priority: .userInitiated) {
                    try ArchiveService.reconstruct(item: item, blobURL: partURL, to: destination)
                }.value
                savedURL = destination
            } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && error.code == NSFileWriteNoPermissionError {
                // App Sandbox blocked the chosen folder (e.g. Documents) — fall back to
                // Downloads, which is always granted, rather than failing the transfer.
                let downloads = try FileManager.default.url(for: .downloadsDirectory,
                                                            in: .userDomainMask,
                                                            appropriateFor: nil, create: true)
                let fallback = uniqueURL(downloads.appendingPathComponent(baseName))
                try await Task.detached(priority: .userInitiated) {
                    try ArchiveService.reconstruct(item: item, blobURL: partURL, to: fallback)
                }.value
                savedURL = fallback
            }
            PartialStore.remove(sha: item.sha256)        // completed — drop the partial
            if firstDestination == nil { firstDestination = savedURL }
            transfer.state = .transferring
        }
        return firstDestination ?? decision.directory
    }

    private func requestApproval(transfer: Transfer, header: TransferHeader,
                                 fingerprint: String, trusted: Bool) async -> ReceiveDecision? {
        if trusted && settings.autoAcceptTrusted {
            return ReceiveDecision(directory: settings.defaultSaveDirectory,
                                   name: header.items.first?.name ?? "received")
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<ReceiveDecision?, Never>) in
            let request = IncomingRequest(transfer: transfer, header: header, fingerprint: fingerprint,
                                          isTrusted: trusted, defaultDirectory: settings.defaultSaveDirectory) { decision in
                cont.resume(returning: decision)
            }
            self.pendingRequest = request
        }
    }

    func resolvePending(_ decision: ReceiveDecision?) {
        let request = pendingRequest
        pendingRequest = nil
        request?.resolve(decision)
    }

    // MARK: Helpers

    private func finish(_ transfer: Transfer, succeeded: Bool) {
        transfer.state = .completed
        transfer.finishTiming()
        history.add(HistoryRecord(date: Date(),
                                  directionIsSend: transfer.direction == .send,
                                  peerName: transfer.peerName,
                                  summary: transfer.primaryName,
                                  bytes: transfer.totalBytes,
                                  succeeded: succeeded))
    }

    private func markCancelled(_ transfer: Transfer) {
        transfer.state = .cancelled
        transfer.finishTiming()
        let role = transfer.direction == .send ? "send" : "receive"
        DebugLog.log("\(role): cancelled '\(transfer.primaryName)' (\(transfer.peerName))", .warn)
        history.add(HistoryRecord(date: Date(),
                                  directionIsSend: transfer.direction == .send,
                                  peerName: transfer.peerName,
                                  summary: transfer.primaryName,
                                  bytes: transfer.bytesTransferred,
                                  succeeded: false))
    }

    private func fail(_ transfer: Transfer, _ error: Error) {
        transfer.state = .failed(error.localizedDescription)
        transfer.finishTiming()
        history.add(HistoryRecord(date: Date(),
                                  directionIsSend: transfer.direction == .send,
                                  peerName: transfer.peerName,
                                  summary: transfer.primaryName,
                                  bytes: transfer.totalBytes,
                                  succeeded: false))
    }

    private func cleanup(_ prepared: [PreparedItem]) {
        for item in prepared where item.blobIsTemporary {
            try? FileManager.default.removeItem(at: item.blobURL)
        }
    }

    /// Reduce an attacker-controlled name to a single safe path component, so a
    /// received name like `../../evil` cannot escape the chosen save directory.
    static func sanitizedComponent(_ raw: String, fallback: String = "received") -> String {
        let comp = (raw as NSString).lastPathComponent
            .replacingOccurrences(of: "\0", with: "")
        if comp.isEmpty || comp == "." || comp == ".." { return fallback }
        return comp
    }

    /// Confirm `url` resolves to a location inside `directory` (defence in depth on
    /// top of name sanitization).
    static func isContained(_ url: URL, in directory: URL) -> Bool {
        let base = directory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return path == base || path.hasPrefix(prefix)
    }

    private func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var i = 1
        while true {
            let name = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }
}
