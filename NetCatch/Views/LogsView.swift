import SwiftUI
import AppKit

struct LogsView: View {
    @ObservedObject private var log = DebugLog.shared
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if log.entries.isEmpty {
                EmptyPlaceholder(title: "No logs yet",
                                 systemImage: "doc.text.magnifyingglass",
                                 message: "Connection and transfer activity will appear here. Try a transfer, then Copy the log.")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(log.entries) { entry in
                                row(entry).id(entry.id)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: log.entries.count) { _ in
                        if let last = log.entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
        .navigationTitle("Logs")
    }

    private var toolbar: some View {
        HStack {
            Text("\(log.entries.count) entries").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(log.transcript(), forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .disabled(log.entries.isEmpty)
            Button(role: .destructive) { log.clear() } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled(log.entries.isEmpty)
        }
        .padding(10)
    }

    private func row(_ entry: DebugLog.Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.time, format: .dateTime.hour().minute().second())
                .foregroundStyle(.secondary)
            Text(entry.message)
                .foregroundStyle(color(for: entry.level))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.system(.caption, design: .monospaced))
    }

    private func color(for level: DebugLog.Level) -> Color {
        switch level {
        case .info: return .primary
        case .warn: return .orange
        case .error: return .red
        }
    }
}
