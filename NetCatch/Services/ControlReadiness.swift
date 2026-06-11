import Foundation
import ApplicationServices
import CoreGraphics
import AppKit

/// Probes whether this Mac can run the planned keyboard/mouse KVM ("Control") feature —
/// i.e. whether the OS will actually grant the input permissions a CGEventTap needs.
///
/// This is the MDM feasibility test: on a managed (work) Mac these toggles are often
/// locked by a configuration profile, which shows up here as red pips that can't be
/// turned green even after using the Grant buttons. Green across the board = KVM is
/// viable on this machine.
@MainActor
final class ControlReadiness: ObservableObject {
    /// Inject + consume events (CGEvent.post / active tap). Backed by Accessibility.
    @Published var accessibility = false
    /// Capture keyboard/mouse globally. Backed by Input Monitoring.
    @Published var inputMonitoring = false
    /// Whether a live event tap can actually be created right now (the real proof).
    @Published var eventTapCreatable = false
    /// App Sandbox is on — global input taps generally require it to be off, so a real
    /// KVM build would need a non-sandboxed target. Surfaced so a red result isn't
    /// misread as "MDM blocked" when it's really the sandbox.
    @Published var sandboxed = false

    var allReady: Bool { accessibility && inputMonitoring && eventTapCreatable }

    init() { refresh() }

    func refresh() {
        accessibility = AXIsProcessTrusted()
        inputMonitoring = CGPreflightListenEventAccess()
        eventTapCreatable = canCreateTap()
        sandboxed = NSHomeDirectory().contains("/Library/Containers/")
    }

    /// Prompt for Accessibility and open the relevant Privacy pane.
    func requestAccessibility() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        openPrivacyPane("Privacy_Accessibility")
        refresh()
    }

    /// Prompt for Input Monitoring and open the relevant Privacy pane.
    func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
        openPrivacyPane("Privacy_ListenEvent")
        refresh()
    }

    func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Try to create a listen-only keyboard tap. Succeeds only if Input Monitoring is
    /// granted and the sandbox/MDM allow it — the most honest single signal.
    private func canCreateTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, _, event, _ in Unmanaged.passUnretained(event) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .listenOnly,
                                          eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: nil) else { return false }
        CFMachPortInvalidate(tap)   // we only needed to know it could be created
        return true
    }
}
