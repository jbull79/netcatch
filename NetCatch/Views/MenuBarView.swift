import SwiftUI
import AppKit

struct MenuBarView: View {
    @EnvironmentObject private var manager: TransferManager
    @EnvironmentObject private var receiver: ReceiverServer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(receiver.isRunning ? .green : .orange).frame(width: 8, height: 8)
                Text(receiver.isRunning ? "Discoverable" : "Offline")
            }
            .padding(.bottom, 4)

            let active = manager.transfers.filter { !$0.state.isTerminal }
            if active.isEmpty {
                Text("No active transfers").foregroundStyle(.secondary)
            } else {
                ForEach(active) { transfer in
                    Text("\(transfer.direction == .send ? "↑" : "↓") \(transfer.primaryName) — \(Format.percent(transfer.progress))")
                }
            }

            Divider()
            Button("Open NetCatch") {
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(10)
        .frame(width: 240)
    }
}
