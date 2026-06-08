import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var history: HistoryStore

    var body: some View {
        Group {
            if history.records.isEmpty {
                ContentUnavailableView("No history",
                                       systemImage: "clock",
                                       description: Text("Completed transfers will be listed here."))
            } else {
                List {
                    ForEach(history.records) { record in
                        HStack(spacing: 10) {
                            Image(systemName: record.directionIsSend ? "arrow.up.circle" : "arrow.down.circle")
                                .foregroundStyle(record.succeeded ? (record.directionIsSend ? .blue : .green) : .red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.summary).fontWeight(.medium)
                                Text("\(record.directionIsSend ? "To" : "From") \(record.peerName) · \(record.date.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(Format.bytes(record.bytes)).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle("History")
        .toolbar {
            if !history.records.isEmpty {
                Button("Clear", role: .destructive) { history.clear() }
            }
        }
    }
}
