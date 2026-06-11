import SwiftUI

/// Per-device service status board. Each row shows a peer's readiness — Workbook (sync)
/// and Control (KVM) — fetched over the encrypted, authenticated link via a status session.
struct ServicesView: View {
    @EnvironmentObject private var manager: TransferManager
    @EnvironmentObject private var discovery: DiscoveryService
    @EnvironmentObject private var settings: AppSettings

    @State private var reports: [String: StatusReport] = [:]
    @State private var querying: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Readiness of each device over the encrypted link. **Workbook** = sync working; **Control** = keyboard/mouse (KVM) ready. Click a device to refresh.")
                    .font(.caption).foregroundStyle(.secondary)

                row(name: "\(settings.deviceName) (this Mac)",
                    workbook: localReport.workbook, control: localReport.control, busy: false)

                if discovery.peers.isEmpty {
                    Label("No other devices found yet.", systemImage: "wifi")
                        .foregroundStyle(.secondary).padding(.top, 6)
                } else {
                    ForEach(discovery.peers) { peer in
                        row(name: peer.name,
                            workbook: reports[peer.id]?.workbook,
                            control: reports[peer.id]?.control,
                            busy: querying.contains(peer.id))
                            .contentShape(Rectangle())
                            .onTapGesture { query(peer) }
                    }
                }
            }
            .padding(22)
        }
        .navigationTitle("Services")
        .toolbar {
            Button { refreshAll() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        }
        .onAppear { refreshAll() }
    }

    private var localReport: StatusReport { manager.localStatusReport() }

    private func row(name: String, workbook: Bool?, control: Bool?, busy: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
            Text(name).fontWeight(.medium).lineLimit(1)
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            servicePip("Workbook", workbook)
            servicePip("Control", control)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
    }

    private func servicePip(_ label: String, _ state: Bool?) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(state == nil ? Color.gray : (state! ? Color.green : Color.red))
                .frame(width: 10, height: 10)
                .overlay(Circle().strokeBorder(.black.opacity(0.15)))
            Text(label).font(.caption)
        }
        .help(state == nil ? "\(label): unknown" : (state! ? "\(label): ready" : "\(label): not ready"))
    }

    private func refreshAll() { for peer in discovery.peers { query(peer) } }

    private func query(_ peer: Peer) {
        guard !querying.contains(peer.id) else { return }
        querying.insert(peer.id)
        Task {
            let report = await manager.queryStatus(of: peer)
            if let report { reports[peer.id] = report }
            querying.remove(peer.id)
        }
    }
}
