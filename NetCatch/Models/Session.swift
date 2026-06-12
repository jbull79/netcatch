import Foundation

/// What a connection is for, negotiated right after the (authenticated) handshake.
/// This is the start of the multiplexing layer: today `transfer` and `status`, with
/// `sync` (workbook) and `control` (KVM) to follow.
enum SessionKind: String, Codable {
    case transfer
    case status
    case control   // keyboard/mouse (KVM) input stream
}

/// Sent by the initiator immediately after the handshake to select the session kind.
struct SessionHello: Codable {
    var kind: SessionKind
    var version: Int = 1
}

/// A device's capability/readiness, exchanged over the authenticated, encrypted link
/// (user-/app-initiated between trusted peers — not a background service).
struct StatusReport: Codable {
    var deviceName: String
    var appVersion: String
    /// Keyboard/mouse control (KVM) readiness — all input permissions granted.
    var control: Bool
    var controlAccessibility: Bool
    var controlInputMonitoring: Bool
    var controlEventTap: Bool
    /// Workbook sync working. False until the feature is built.
    var workbook: Bool
}
