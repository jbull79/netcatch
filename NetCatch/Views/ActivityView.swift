import SwiftUI

struct ActivityView: View {
    @EnvironmentObject private var manager: TransferManager

    var body: some View {
        Group {
            if manager.transfers.isEmpty {
                ContentUnavailableView("No transfers yet",
                                       systemImage: "arrow.up.arrow.down.circle",
                                       description: Text("Sends and receives will appear here."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(manager.transfers) { transfer in
                            TransferRow(transfer: transfer)
                        }
                    }
                    .padding(18)
                }
            }
        }
        .navigationTitle("Activity")
    }
}
