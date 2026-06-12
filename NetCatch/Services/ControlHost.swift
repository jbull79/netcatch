import Foundation
import AppKit
import CoreGraphics

/// The *controlling* (work) side of KVM. Opens a `.control` session to a peer and, while
/// capturing, forwards local keyboard/mouse to it. Capture uses an in-window `NSEvent`
/// local monitor — no Accessibility / Input Monitoring needed, so it works on a
/// locked-down Mac. Press the release hotkey (⌃⌥⌘) or switch away to drop control.
@MainActor
final class ControlHost: ObservableObject {
    enum State: Equatable { case idle, connecting, connected, capturing }

    @Published var state: State = .idle
    @Published var peerName: String?
    @Published var lastError: String?

    private var link: PeerLink?
    private var monitor: Any?
    private var continuation: AsyncStream<ControlEvent>.Continuation?
    private var sendTask: Task<Void, Never>?

    // Mouse-move coalescing — accumulate deltas, flush at a fixed rate so a fast mouse
    // doesn't flood the link (which makes the pointer jerky).
    private var pendingDX = 0.0
    private var pendingDY = 0.0
    private var lastFlags: UInt64 = 0
    private var flushTimer: Task<Void, Never>?

    init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.endCapture() }   // lost focus → stop, no stuck keys
        }
    }

    // MARK: Connect

    func connect(to peer: Peer, localName: String) {
        guard state == .idle else { return }
        state = .connecting; peerName = peer.name; lastError = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let link = try await TransportConnector.shared.connect(to: peer, localName: localName)
                try await link.sendSecureObject(SessionHello(kind: .control))
                // Wait for the peer to accept before we ever capture / hijack the cursor.
                let ack = try await link.receiveSecureObject(ControlAck.self)
                guard ack.accepted else {
                    link.cancel()
                    self.lastError = ack.reason.isEmpty ? "\(peer.name) is not accepting control." : ack.reason
                    self.state = .idle
                    DebugLog.log("control host: peer refused — \(self.lastError ?? "")", .warn)
                    return
                }
                self.link = link
                self.startSendLoop()
                self.state = .connected
                DebugLog.log("control host: connected to \(peer.name)")
            } catch {
                self.lastError = error.localizedDescription
                self.state = .idle
                DebugLog.log("control host: connect failed — \(error.localizedDescription)", .error)
            }
        }
    }

    func disconnect() {
        endCapture()
        continuation?.finish(); continuation = nil
        sendTask?.cancel(); sendTask = nil
        link?.cancel(); link = nil
        state = .idle; peerName = nil
    }

    private func startSendLoop() {
        let stream = AsyncStream<ControlEvent> { self.continuation = $0 }
        sendTask = Task { [weak self] in
            for await event in stream {
                guard let link = await self?.link else { break }
                do { try await link.sendSecureObject(event) }
                catch {
                    await MainActor.run { self?.disconnect() }
                    break
                }
            }
        }
    }

    private func send(_ event: ControlEvent) { continuation?.yield(event) }

    // MARK: Capture

    func beginCapture() {
        guard state == .connected, link != nil else { return }   // never hijack without a live session
        installMonitor()
        CGDisplayHideCursor(CGMainDisplayID())
        CGAssociateMouseAndMouseCursorPosition(0)   // decouple hardware mouse from cursor
        state = .capturing
        startFlushTimer()
        DebugLog.log("control host: capture begin")
    }

    func endCapture() {
        guard state == .capturing else { return }
        state = .connected                          // set first — prevents reentrancy
        flushTimer?.cancel(); flushTimer = nil
        flushMove()
        CGAssociateMouseAndMouseCursorPosition(1)   // always restore the cursor
        CGDisplayShowCursor(CGMainDisplayID())
        send(ControlEvent(kind: .releaseAll))
        DebugLog.log("control host: capture end")
    }

    private func startFlushTimer() {
        flushTimer?.cancel()
        flushTimer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000)   // ~120 Hz
                self?.flushMove()
            }
        }
    }

    private func flushMove() {
        guard pendingDX != 0 || pendingDY != 0 else { return }
        send(ControlEvent(kind: .mouseMove, dx: pendingDX, dy: pendingDY, flags: lastFlags))
        pendingDX = 0; pendingDY = 0
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [
            .keyDown, .keyUp, .flagsChanged,
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .scrollWheel
        ]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self, self.state == .capturing else { return event }
            // Release hotkey: control + option + command held together.
            if event.type == .flagsChanged {
                let f = event.modifierFlags
                if f.contains(.control), f.contains(.option), f.contains(.command) {
                    self.endCapture(); return nil
                }
            }
            guard let ce = self.translate(event) else { return nil }
            self.lastFlags = ce.flags
            if ce.kind == .mouseMove {
                self.pendingDX += ce.dx                 // coalesce; flushed on the timer
                self.pendingDY += ce.dy
            } else {
                self.flushMove()                        // keep clicks/keys positioned correctly
                self.send(ce)
            }
            return nil   // consume so the work Mac doesn't also act on it
        }
    }

    private func translate(_ e: NSEvent) -> ControlEvent? {
        let flags = cgFlags(e.modifierFlags)
        switch e.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return ControlEvent(kind: .mouseMove, dx: e.deltaX, dy: e.deltaY, flags: flags)
        case .leftMouseDown:  return ControlEvent(kind: .mouseDown, button: 0, flags: flags)
        case .leftMouseUp:    return ControlEvent(kind: .mouseUp, button: 0, flags: flags)
        case .rightMouseDown: return ControlEvent(kind: .mouseDown, button: 1, flags: flags)
        case .rightMouseUp:   return ControlEvent(kind: .mouseUp, button: 1, flags: flags)
        case .otherMouseDown: return ControlEvent(kind: .mouseDown, button: 2, flags: flags)
        case .otherMouseUp:   return ControlEvent(kind: .mouseUp, button: 2, flags: flags)
        case .scrollWheel:    return ControlEvent(kind: .scroll, scrollX: e.scrollingDeltaX, scrollY: e.scrollingDeltaY, flags: flags)
        case .keyDown:        return ControlEvent(kind: .keyDown, keyCode: Int(e.keyCode), flags: flags)
        case .keyUp:          return ControlEvent(kind: .keyUp, keyCode: Int(e.keyCode), flags: flags)
        case .flagsChanged:   return ControlEvent(kind: .flagsChanged, flags: flags)
        default: return nil
        }
    }

    private func cgFlags(_ mf: NSEvent.ModifierFlags) -> UInt64 {
        var cg: CGEventFlags = []
        if mf.contains(.shift)    { cg.insert(.maskShift) }
        if mf.contains(.control)  { cg.insert(.maskControl) }
        if mf.contains(.option)   { cg.insert(.maskAlternate) }
        if mf.contains(.command)  { cg.insert(.maskCommand) }
        if mf.contains(.capsLock) { cg.insert(.maskAlphaShift) }
        if mf.contains(.function) { cg.insert(.maskSecondaryFn) }
        return cg.rawValue
    }
}
