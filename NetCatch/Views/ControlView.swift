import SwiftUI

/// Drive another Mac's keyboard/mouse (KVM). Work Mac = controller. Capture happens in
/// this window (no special permission); the controlled Mac needs Accessibility.
struct ControlView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var discovery: DiscoveryService
    @StateObject private var host = ControlHost()

    @State private var selectedPeerID: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !settings.controlEnabled {
                    enableCard
                } else {
                    peerPicker
                    connectionArea
                }
            }
            .padding(22)
        }
        .navigationTitle("Control")
        .onDisappear { host.disconnect() }
    }

    private var enableCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Experimental", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.headline)
            Text("Control another Mac's keyboard and mouse over the LAN. The controlled Mac must enable this too and grant Accessibility. While controlling, your input drives the other Mac and won't affect this one.")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("Enable Control", isOn: $settings.controlEnabled)
                .toggleStyle(.switch)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
    }

    private var peerPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Control which Mac").font(.headline)
            if discovery.peers.isEmpty {
                Label("No devices found.", systemImage: "wifi").foregroundStyle(.secondary)
            } else {
                Picker("Peer", selection: $selectedPeerID) {
                    Text("Choose…").tag(String?.none)
                    ForEach(discovery.peers) { peer in
                        Text(peer.name).tag(Optional(peer.id))
                    }
                }
                .labelsHidden()
                .disabled(host.state != .idle)
            }
        }
    }

    @ViewBuilder private var connectionArea: some View {
        switch host.state {
        case .idle:
            Button("Connect") {
                if let peer = discovery.peers.first(where: { $0.id == selectedPeerID }) {
                    host.connect(to: peer, localName: settings.deviceName)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedPeerID == nil)
            if let err = host.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        case .connecting:
            HStack { ProgressView().controlSize(.small); Text("Connecting to \(host.peerName ?? "")…") }
        case .connected, .capturing:
            captureArea
            Button("Disconnect") { host.disconnect() }.buttonStyle(.bordered)
        }
    }

    private var captureArea: some View {
        let capturing = host.state == .capturing
        return VStack(spacing: 12) {
            Image(systemName: capturing ? "keyboard.fill" : "keyboard")
                .font(.system(size: 40))
                .foregroundStyle(capturing ? Color.accentColor : .secondary)
            Text(capturing ? "Controlling \(host.peerName ?? "")"
                           : "Click here to control \(host.peerName ?? "")")
                .font(.headline)
            Text(capturing ? "Press ⌃⌥⌘ (control-option-command) to release."
                           : "Your keyboard & mouse will drive the other Mac. Watch its screen.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .background(RoundedRectangle(cornerRadius: 16)
            .fill(capturing ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(capturing ? Color.accentColor : Color.secondary.opacity(0.3),
                          style: StrokeStyle(lineWidth: 2, dash: capturing ? [] : [8])))
        .contentShape(Rectangle())
        .onTapGesture { if !capturing { host.beginCapture() } }
    }
}
