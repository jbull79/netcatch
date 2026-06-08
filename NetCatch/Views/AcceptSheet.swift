import SwiftUI
import AppKit

struct AcceptSheet: View {
    @EnvironmentObject private var manager: TransferManager
    @ObservedObject var request: IncomingRequest

    @State private var destination: URL
    @State private var name: String

    init(request: IncomingRequest) {
        self.request = request
        _destination = State(initialValue: request.defaultDirectory)
        _name = State(initialValue: request.suggestedName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            itemList
            Divider()
            saveControls
            footer
        }
        .padding(22)
        .frame(width: 460)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 3) {
                Text("Incoming transfer").font(.title3).fontWeight(.semibold)
                Text("From \(request.header.senderName)").foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Image(systemName: request.isTrusted ? "checkmark.seal.fill" : "seal")
                        .foregroundStyle(request.isTrusted ? .green : .secondary)
                    Text(request.fingerprint)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if request.isTrusted {
                        Text("· known device").font(.caption).foregroundStyle(.green)
                    }
                }
            }
            Spacer()
        }
    }

    private var itemList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(request.header.items) { item in
                HStack(spacing: 10) {
                    Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                        .foregroundStyle(.tint)
                    Text(item.name).lineLimit(1)
                    Spacer()
                    if item.compressed && item.ratioSaved > 0.01 {
                        Text("saved \(Format.percent(item.ratioSaved))")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.green.opacity(0.15)))
                            .foregroundStyle(.green)
                    }
                    Text(Format.bytes(item.originalSize))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var saveControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if request.header.items.count == 1 {
                HStack {
                    Text("Save as").frame(width: 60, alignment: .leading)
                    TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                }
            }
            HStack {
                Text("Where").frame(width: 60, alignment: .leading)
                Text(destination.path)
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Choose…", action: chooseFolder)
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Decline", role: .cancel) { manager.resolvePending(nil) }
                .keyboardShortcut(.cancelAction)
            Button("Accept & Save") {
                manager.resolvePending(ReceiveDecision(directory: destination, name: name))
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = destination
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            destination = url
        }
    }
}
