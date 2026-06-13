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

    // Mouse-move coalescing — accumulate deltas in a lock-guarded buffer, flushed on a
    // precise off-main timer so the cursor stream has a steady cadence (no Task.sleep /
    // main-actor jitter, which caused stutter).
    private let moveBuffer = MoveBuffer()
    private let flushQueue = DispatchQueue(label: "netcatch.control.flush", qos: .userInteractive)
    private var flushTimer: DispatchSourceTimer?

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
        link?.cancel(); link = nil
        state = .idle; peerName = nil
    }

    /// Send a discrete event (click/key/releaseAll) on the flush queue, flushing any
    /// pending mouse move first so it stays correctly positioned. Synchronous write — no
    /// async send-task that would batch frames and clump them on the wire.
    private func sendOnQueue(_ event: ControlEvent) {
        guard let link = link else { return }
        let buf = moveBuffer
        flushQueue.async { [weak self] in
            if let m = buf.take() {
                _ = link.sendSecureObjectSync(ControlEvent(kind: .mouseMove, dx: m.dx, dy: m.dy, flags: m.flags))
            }
            if !link.sendSecureObjectSync(event) {
                Task { @MainActor in self?.disconnect() }
            }
        }
    }

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
        CGAssociateMouseAndMouseCursorPosition(1)   // always restore the cursor
        CGDisplayShowCursor(CGMainDisplayID())
        sendOnQueue(ControlEvent(kind: .releaseAll))   // flushes pending move + releaseAll
        DebugLog.log("control host: capture end")
    }

    private func startFlushTimer() {
        flushTimer?.cancel()
        guard let link = link else { return }       // captured (Sendable) — used on the timer queue
        let buf = moveBuffer
        let timer = DispatchSource.makeTimerSource(queue: flushQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .nanoseconds(0))
        var sent = 0, ticks = 0
        var window = DispatchTime.now()
        timer.setEventHandler { [weak self] in
            ticks += 1
            if let m = buf.take() {
                if link.sendSecureObjectSync(ControlEvent(kind: .mouseMove, dx: m.dx, dy: m.dy, flags: m.flags)) {
                    sent += 1
                } else {
                    Task { @MainActor in self?.disconnect() }
                }
            }
            let now = DispatchTime.now()
            if now.uptimeNanoseconds - window.uptimeNanoseconds >= 1_000_000_000 {
                DebugLog.log("control host: \(sent) moves/s sent (\(ticks) timer ticks/s)")
                _ = link.sendSecureObjectSync(ControlEvent(kind: .hostStats, dx: Double(sent), dy: Double(ticks)))
                sent = 0; ticks = 0; window = now
            }
        }
        timer.resume()
        flushTimer = timer
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
            if ce.kind == .mouseMove {
                self.moveBuffer.add(dx: ce.dx, dy: ce.dy, flags: ce.flags)   // coalesced, flushed by timer
            } else {
                self.sendOnQueue(ce)                    // flushes pending move, keeps clicks positioned
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

    // Thread-safe accumulator for coalesced mouse deltas (written on main, drained by the
    // flush timer on its own queue).
    final class MoveBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var dx = 0.0, dy = 0.0, flags: UInt64 = 0, dirty = false
        func add(dx: Double, dy: Double, flags: UInt64) {
            lock.lock(); self.dx += dx; self.dy += dy; self.flags = flags; dirty = true; lock.unlock()
        }
        func take() -> (dx: Double, dy: Double, flags: UInt64)? {
            lock.lock(); defer { lock.unlock() }
            guard dirty else { return nil }
            let r = (dx, dy, flags); dx = 0; dy = 0; dirty = false; return r
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
