import Foundation
import CoreGraphics

/// Injects forwarded input on the *controlled* (home) Mac via CGEvent.post. Requires
/// Accessibility (grantable, no admin). Runs off the main actor.
///
/// Mouse moves are *paced*: incoming deltas accumulate in a buffer and are drained on a
/// steady local 120 Hz timer, so bursty network delivery (events arriving clumped with
/// 200–500 ms gaps) is smoothed into even pointer motion instead of stutter. Clicks/keys
/// flush the buffer first so they land at the right position.
final class ControlInjector: @unchecked Sendable {
    private let bounds: CGRect
    private var cursor: CGPoint
    private var flags: CGEventFlags = []
    private var heldKeys: Set<CGKeyCode> = []
    private var mouseDown = false
    private let source = CGEventSource(stateID: .hidSystemState)

    /// When the injected cursor reaches this edge, control should return to the host.
    var returnEdge: ScreenEdge?
    var onReturn: (() -> Void)?
    private var wasAtReturnEdge = false

    // Pacing
    private let lock = NSLock()
    private var pendDX = 0.0, pendDY = 0.0
    private var timer: DispatchSourceTimer?
    // Fraction of the remaining buffered movement applied per 120 Hz tick. Lower = motion
    // is spread across more ticks → fills the ~100 ms Wi-Fi delivery gaps with continuous
    // glide instead of a quick burst then freeze. Trades a little latency for smoothness.
    private let drainFactor = 0.25

    init() {
        bounds = CGDisplayBounds(CGMainDisplayID())
        cursor = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "netcatch.inject", qos: .userInteractive))
        t.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .nanoseconds(0))
        t.setEventHandler { [weak self] in self?.drain() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel(); timer = nil
        flushPendingMove()
        releaseAll()
    }

    func apply(_ e: ControlEvent) {
        switch e.kind {
        case .mouseMove:
            lock.lock(); pendDX += e.dx; pendDY += e.dy; lock.unlock()
        case .mouseDown:
            flushPendingMove()
            if e.button == 0 { mouseDown = true }
            postMouse(downType(e.button), button: cgButton(e.button))
        case .mouseUp:
            flushPendingMove()
            if e.button == 0 { mouseDown = false }
            postMouse(upType(e.button), button: cgButton(e.button))
        case .scroll:
            CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                    wheel1: Int32(e.scrollY), wheel2: Int32(e.scrollX), wheel3: 0)?
                .post(tap: .cghidEventTap)
        case .keyDown:
            flags = CGEventFlags(rawValue: e.flags)
            postKey(CGKeyCode(e.keyCode), down: true)
            heldKeys.insert(CGKeyCode(e.keyCode))
        case .keyUp:
            flags = CGEventFlags(rawValue: e.flags)
            postKey(CGKeyCode(e.keyCode), down: false)
            heldKeys.remove(CGKeyCode(e.keyCode))
        case .flagsChanged:
            flags = CGEventFlags(rawValue: e.flags)
        case .releaseAll:
            releaseAll()
        case .hostStats:
            break
        }
    }

    func releaseAll() {
        for key in heldKeys { postKey(key, down: false) }
        heldKeys.removeAll()
        if mouseDown { postMouse(.leftMouseUp, button: .left); mouseDown = false }
        flags = []
    }

    // MARK: Paced mouse motion

    /// Drain a fraction of the buffered movement (called on the local timer) → smooth.
    private func drain() {
        lock.lock()
        guard pendDX != 0 || pendDY != 0 else { lock.unlock(); return }
        let stepX: Double, stepY: Double
        if abs(pendDX) < 2 && abs(pendDY) < 2 {       // finish off the remainder
            stepX = pendDX; stepY = pendDY
        } else {
            stepX = pendDX * drainFactor; stepY = pendDY * drainFactor
        }
        pendDX -= stepX; pendDY -= stepY
        lock.unlock()
        moveBy(stepX, stepY)
    }

    /// Apply all buffered movement immediately (before a click/key, or at stop).
    private func flushPendingMove() {
        lock.lock(); let dx = pendDX, dy = pendDY; pendDX = 0; pendDY = 0; lock.unlock()
        if dx != 0 || dy != 0 { moveBy(dx, dy) }
    }

    private func moveBy(_ dx: Double, _ dy: Double) {
        cursor.x = min(max(bounds.minX, cursor.x + dx), bounds.maxX - 1)
        cursor.y = min(max(bounds.minY, cursor.y + dy), bounds.maxY - 1)
        postMouse(mouseDown ? .leftMouseDragged : .mouseMoved, button: .left)
        checkReturnEdge()
    }

    /// Fire onReturn once when the cursor first reaches the return edge.
    private func checkReturnEdge() {
        guard let e = returnEdge else { return }
        let hit: Bool
        switch e {
        case .right:  hit = cursor.x >= bounds.maxX - 1
        case .left:   hit = cursor.x <= bounds.minX
        case .top:    hit = cursor.y <= bounds.minY
        case .bottom: hit = cursor.y >= bounds.maxY - 1
        }
        if hit && !wasAtReturnEdge { onReturn?() }
        wasAtReturnEdge = hit
    }

    // MARK: CGEvent helpers

    private func postMouse(_ type: CGEventType, button: CGMouseButton) {
        let event = CGEvent(mouseEventSource: source, mouseType: type,
                            mouseCursorPosition: cursor, mouseButton: button)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    private func postKey(_ code: CGKeyCode, down: Bool) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    private func cgButton(_ b: Int) -> CGMouseButton { b == 1 ? .right : (b == 2 ? .center : .left) }
    private func downType(_ b: Int) -> CGEventType { b == 1 ? .rightMouseDown : (b == 2 ? .otherMouseDown : .leftMouseDown) }
    private func upType(_ b: Int) -> CGEventType { b == 1 ? .rightMouseUp : (b == 2 ? .otherMouseUp : .leftMouseUp) }
}
