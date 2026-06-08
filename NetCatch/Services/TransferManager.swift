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

    private let chunkSize = 256 * 1024

    init(settings: AppSettings, history: HistoryStore) {
        self.settings = settings
        self.history = history
        receiver.onIncoming = { [weak self] connection in
            self?.handleIncoming(connection)
        }
    }

    func startServices() {
        discovery.ownServiceName = settings.deviceName
        receiver.start(serviceName: settings.deviceName, port: settings.port)
        discovery.start()
        NotificationService.requestAuthorization()
    }

    func restartServices() {
        receiver.stop()
        discovery.stop()
        startServices()
    }

    // MARK: Sending

    func send(urls: [URL], to peer: Peer, compress: Bool) {
        Task { await runSend(urls: urls, peer: peer, compress: compress) }
    }

    private func runSend(urls: [URL], peer: Peer, compress: Bool) async {
        let transfer = Transfer(direction: .send, peerName: peer.name, items: [], totalBytes: 0)
        transfer.state = .connecting
        transfers.insert(transfer, at: 0)

        var prepared: [PreparedItem] = []
        do {
            prepared = try await Task.detached(priority: .userInitiated) {
                try urls.map { try ArchiveService.prepare(url: $0, compressRequested: compress) }
            }.value

            let header = TransferHeader(senderName: settings.deviceName, items: prepared.map(\.item))
            transfer.items = header.items
            transfer.totalBytes = header.totalTransmitted

            let params = NWParameters.tcp
            params.includePeerToPeer = true
            let link = PeerLink(connection: NWConnection(to: peer.endpoint, using: params))
            try await link.start()
            try await link.handshake(localName: settings.deviceName)
            transfer.peerName = link.remoteName == "Unknown" ? peer.name : link.remoteName
            transfer.peerFingerprint = link.remoteFingerprint

            try await link.sendSecureObject(header)
            let decision = try await link.receiveSecureObject(TransferDecision.self)
            guard decision.accepted else {
                transfer.state = .rejected
                link.cancel()
                cleanup(prepared)
                return
            }

            transfer.state = .transferring
            for item in prepared {
                try await sendBlob(link: link, prepared: item, transfer: transfer)
            }
            link.cancel()
            finish(transfer, succeeded: true)
        } catch {
            fail(transfer, error)
        }
        cleanup(prepared)
    }

    private func sendBlob(link: PeerLink, prepared: PreparedItem, transfer: Transfer) async throws {
        let handle = try FileHandle(forReadingFrom: prepared.blobURL)
        defer { try? handle.close() }
        var offset: UInt64 = 0
        while true {
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

    private func handleIncoming(_ connection: NWConnection) {
        let link = PeerLink(connection: connection)
        Task { await runReceive(link: link) }
    }

    private func runReceive(link: PeerLink) async {
        let transfer = Transfer(direction: .receive, peerName: "Incoming…", items: [], totalBytes: 0)
        do {
            try await link.start()
            try await link.handshake(localName: settings.deviceName)
            let header = try await link.receiveSecureObject(TransferHeader.self)

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
            transfer.state = .transferring
            let location = try await receivePayload(link: link, header: header, decision: decision, transfer: transfer)
            transfer.savedLocation = location
            link.cancel()
            finish(transfer, succeeded: true)
            NotificationService.notify(title: "Received from \(transfer.peerName)",
                                       body: transfer.primaryName)
        } catch {
            fail(transfer, error)
            link.cancel()
        }
    }

    private func receivePayload(link: PeerLink, header: TransferHeader,
                               decision: ReceiveDecision, transfer: Transfer) async throws -> URL {
        let scoped = decision.directory.startAccessingSecurityScopedResource()
        defer { if scoped { decision.directory.stopAccessingSecurityScopedResource() } }

        var firstDestination: URL?
        for (index, item) in header.items.enumerated() {
            let tempURL = ArchiveService.tempDirectory().appendingPathComponent(UUID().uuidString + ".blob")
            FileManager.default.createFile(atPath: tempURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: tempURL)

            var received: Int64 = 0
            while received < item.transmittedSize {
                let frame = try await link.receiveSecure()
                guard frame.count >= 8 else { throw LinkError.malformed }
                let offset = frame.prefix(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.bigEndian
                let payload = frame.dropFirst(8)
                try handle.seek(toOffset: offset)
                handle.write(Data(payload))
                received += Int64(payload.count)
                transfer.advance(by: Int64(payload.count))
            }
            try? handle.close()

            transfer.state = .verifying
            let digest = try await Task.detached(priority: .userInitiated) {
                try CryptoService.sha256Hex(ofFileAt: tempURL)
            }.value
            guard digest == item.sha256 else { throw LinkError.integrityMismatch(item.name) }

            let baseName = Self.sanitizedComponent(index == 0 ? decision.name : item.name)
            let target = decision.directory.appendingPathComponent(baseName)
            guard Self.isContained(target, in: decision.directory) else { throw LinkError.malformed }
            let destination = uniqueURL(target)
            try await Task.detached(priority: .userInitiated) {
                try ArchiveService.reconstruct(item: item, blobURL: tempURL, to: destination)
            }.value
            try? FileManager.default.removeItem(at: tempURL)
            if firstDestination == nil { firstDestination = destination }
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
        transfer.throughput = 0
        history.add(HistoryRecord(date: Date(),
                                  directionIsSend: transfer.direction == .send,
                                  peerName: transfer.peerName,
                                  summary: transfer.primaryName,
                                  bytes: transfer.totalBytes,
                                  succeeded: succeeded))
    }

    private func fail(_ transfer: Transfer, _ error: Error) {
        transfer.state = .failed(error.localizedDescription)
        transfer.throughput = 0
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
