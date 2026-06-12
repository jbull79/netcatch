import Foundation

/// One input event forwarded host → client over a `.control` session. Mouse moves are
/// relative deltas (the client keeps its own virtual cursor), so both capture modes
/// (edge-tap and focused-window) feed the same stream.
enum ControlEventKind: String, Codable {
    case mouseMove
    case mouseDown
    case mouseUp
    case scroll
    case keyDown
    case keyUp
    case flagsChanged
    case releaseAll   // disconnect / focus loss — client releases everything held
    case hostStats    // host→client diagnostics (dx=moves/s sent, dy=timer ticks/s); not injected
}

/// Controlled Mac's reply to a control request: whether it will accept input.
struct ControlAck: Codable {
    var accepted: Bool
    var reason: String = ""
}

struct ControlEvent: Codable {
    var kind: ControlEventKind
    var dx: Double = 0
    var dy: Double = 0
    var button: Int = 0          // 0 left, 1 right, 2 other
    var scrollX: Double = 0
    var scrollY: Double = 0
    var keyCode: Int = 0         // virtual keycode
    var flags: UInt64 = 0        // CGEventFlags raw (modifier state)
}
