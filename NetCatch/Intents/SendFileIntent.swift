import AppIntents
import Foundation

/// Shortcuts / Siri action: "Send Files with NetCatch". Sends one or more files to a
/// Mac on the local network. If the named device isn't found (or none is given), the
/// app opens with the files queued so you can pick a destination.
struct SendFileIntent: AppIntent {
    static var title: LocalizedStringResource = "Send Files with NetCatch"
    static var description = IntentDescription(
        "Send files to another Mac on your local network using NetCatch.")
    static var openAppWhenRun = true

    @Parameter(title: "Files", supportedTypeIdentifiers: ["public.item"])
    var files: [IntentFile]

    @Parameter(title: "To Device",
               description: "Name of the Mac to send to, as shown in NetCatch. Leave empty to choose in the app.")
    var peer: String?

    @Parameter(title: "Compress", default: true)
    var compress: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$files) to \(\.$peer)") {
            \.$compress
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let urls = try files.map { try $0.materializeForSending() }
        // User-authored Shortcut → consent is explicit, so a direct send is allowed.
        let started = await AppModel.shared.sendViaAutomation(
            urls: urls, peerName: peer, compress: compress, confirm: false)
        // Either a transfer started, or the app opened with the files queued.
        _ = started
        return .result()
    }
}

/// Surfaces the action in the Shortcuts gallery and to Siri automatically.
struct NetCatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendFileIntent(),
            phrases: [
                "Send files with \(.applicationName)",
                "Send with \(.applicationName)"
            ],
            shortTitle: "Send Files",
            systemImageName: "paperplane.fill"
        )
    }
}

private extension IntentFile {
    /// Copy the provided file into our temp area so we fully own it for the duration
    /// of the (possibly async) transfer, independent of any security scope.
    func materializeForSending() throws -> URL {
        let dir = ArchiveService.tempDirectory()
            .appendingPathComponent("intent-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = filename.isEmpty ? UUID().uuidString : filename
        let dest = dir.appendingPathComponent(name)
        if let url = fileURL {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            try FileManager.default.copyItem(at: url, to: dest)
        } else {
            try data.write(to: dest)
        }
        return dest
    }
}
