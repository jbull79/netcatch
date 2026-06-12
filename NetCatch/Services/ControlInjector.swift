import Foundation
import CoreGraphics

/// Injects forwarded input events on the *controlled* (home) Mac via CGEvent.post.
/// Requires Accessibility (grantable on the home Mac, no admin). Keeps a virtual cursor
/// clamped to the main display and tracks held keys so they can be released on
/// disconnect (no stuck modifiers).
@MainActor
final class ControlInjector {
    private let bounds: CGRect
    private var cursor: CGPoint
    private var flags: CGEventFlags = []
    private var heldKeys: Set<CGKeyCode> = []
    private var mouseDown = false
    private let source = CGEventSource(stateID: .hidSystemState)

    init() {
        bounds = CGDisplayBounds(CGMainDisplayID())
        cursor = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    func apply(_ e: ControlEvent) {
        switch e.kind {
        case .mouseMove:
            cursor.x = min(max(bounds.minX, cursor.x + e.dx), bounds.maxX - 1)
            cursor.y = min(max(bounds.minY, cursor.y + e.dy), bounds.maxY - 1)
            postMouse(mouseDown ? .leftMouseDragged : .mouseMoved, button: .left)
        case .mouseDown:
            if e.button == 0 { mouseDown = true }
            postMouse(downType(e.button), button: cgButton(e.button))
        case .mouseUp:
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
        }
    }

    /// Release everything held — call on disconnect / focus loss.
    func releaseAll() {
        for key in heldKeys { postKey(key, down: false) }
        heldKeys.removeAll()
        if mouseDown { postMouse(.leftMouseUp, button: .left); mouseDown = false }
        flags = []
    }

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
