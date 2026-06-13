import SwiftUI

/// Shared notebook synced across devices. Add/edit/delete notes; changes sync to peers
/// (manual Sync button + on appear). Multi-person: each note shows who last edited it.
struct WorkbookView: View {
    @EnvironmentObject private var manager: TransferManager
    @EnvironmentObject private var workbook: WorkbookStore

    @State private var draft = ""
    @State private var editingID: UUID?
    @State private var editText = ""

    private var canAdd: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            composer
            Divider()
            if workbook.entries.isEmpty {
                EmptyPlaceholder(title: "Workbook is empty",
                                 systemImage: "book",
                                 message: "Add a note — it syncs to your other Macs running NetCatch.")
            } else {
                List {
                    ForEach(workbook.entries) { entry in row(entry) }
                }
            }
            if let last = workbook.lastSynced {
                Text("Last synced \(last.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing).padding(6)
            }
        }
        .navigationTitle("Workbook")
        .toolbar {
            Button { Task { await manager.syncAllPeers() } } label: {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .onAppear { Task { await manager.syncAllPeers() } }
    }

    private var composer: some View {
        HStack {
            TextField("Add a note…", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(addDraft)
            Button("Add", action: addDraft).disabled(!canAdd)
        }
        .padding(12)
    }

    @ViewBuilder private func row(_ entry: WorkbookEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if editingID == entry.id {
                TextField("Note", text: $editText).textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel") { editingID = nil }
                    Button("Save") {
                        workbook.update(entry.id, text: editText); editingID = nil
                        Task { await manager.syncAllPeers() }
                    }.buttonStyle(.borderedProminent)
                }
            } else {
                Text(entry.text)
                HStack(spacing: 8) {
                    Text(workbook.isLocal(entry) ? "You" : "Device \(entry.author.prefix(9))")
                    Text("·")
                    Text(entry.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    Spacer()
                    Button("Edit") { editingID = entry.id; editText = entry.text }.buttonStyle(.link)
                    Button("Delete") {
                        workbook.delete(entry.id)
                        Task { await manager.syncAllPeers() }
                    }.buttonStyle(.link).foregroundStyle(.red)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func addDraft() {
        guard canAdd else { return }
        workbook.add(text: draft.trimmingCharacters(in: .whitespacesAndNewlines))
        draft = ""
        Task { await manager.syncAllPeers() }
    }
}
