import SwiftUI
import AppKit

/// Top-level app state, shared across the main window, menu bar, and the Finder
/// "Send with NetCatch" service.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let settings = AppSettings()
    let history = HistoryStore()
    let manager: TransferManager

    /// URLs queued for sending (from the file picker, drag-and-drop, or Finder service).
    @Published var pendingSendURLs: [URL] = []

    private init() {
        manager = TransferManager(settings: settings, history: history)
    }

    func start() {
        manager.startServices()
    }

    func queueSend(urls: [URL]) {
        guard !urls.isEmpty else { return }
        pendingSendURLs = urls
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Send triggered by an external entry point. `confirm` MUST be true for any
    /// web-triggerable source (the `netcatch://` URL scheme): in that case we never
    /// auto-send — we just queue the files in the Send pane so the user explicitly
    /// picks a destination. Only the user-authored Shortcuts action passes
    /// `confirm: false`, allowing a direct send to a named peer. Returns true if a
    /// transfer actually started.
    @discardableResult
    func sendViaAutomation(urls: [URL], peerName: String?, compress: Bool?, confirm: Bool) async -> Bool {
        let files = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { return false }

        // Untrusted/web-triggered source → require an explicit on-screen confirmation.
        if confirm {
            queueSend(urls: files)
            return false
        }

        let doCompress = compress ?? settings.compressByDefault
        NSApp.activate(ignoringOtherApps: true)
        manager.discovery.start()   // idempotent; make sure we're browsing

        if let name = peerName, !name.isEmpty {
            for _ in 0..<60 {       // wait up to ~6s for the named peer to appear
                if let peer = manager.discovery.peers.first(where: {
                    $0.name.caseInsensitiveCompare(name) == .orderedSame
                }) {
                    manager.send(urls: files, to: peer, compress: doCompress)
                    return true
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        queueSend(urls: files)      // fall back to manual peer choice
        return false
    }
}

/// Receives file URLs from the Finder right-click "Send with NetCatch" service.
final class ServiceHandler: NSObject {
    @objc func sendWithNetCatch(_ pboard: NSPasteboard, userData: String?,
                                error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
        Task { @MainActor in AppModel.shared.queueSend(urls: urls) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let serviceHandler = ServiceHandler()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = serviceHandler
        NSUpdateDynamicServices()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // Route file:// (queued for manual pick) and netcatch://send?… (optionally to a
        // named peer) through the shared automation entry point.
        for url in urls {
            guard let req = AutomationRouter.parse(url) else { continue }
            Task { @MainActor in
                // URL scheme is web-triggerable → require explicit confirmation.
                await AppModel.shared.sendViaAutomation(urls: req.urls,
                                                        peerName: req.peerName,
                                                        compress: req.compress,
                                                        confirm: true)
            }
        }
    }
}

@main
struct NetCatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.manager)
                .environmentObject(model.settings)
                .environmentObject(model.history)
                .environmentObject(model.manager.discovery)
                .environmentObject(model.manager.receiver)
                .environmentObject(model.manager.trust)
                .frame(minWidth: 760, minHeight: 520)
                .onAppear { model.start() }
        }
        .windowToolbarStyle(.unified)

        MenuBarExtra("NetCatch", systemImage: "antenna.radiowaves.left.and.right") {
            MenuBarView()
                .environmentObject(model)
                .environmentObject(model.manager)
                .environmentObject(model.manager.receiver)
        }

        Settings {
            SettingsView()
                .environmentObject(model.settings)
                .environmentObject(model.manager)
                .environmentObject(model.history)
                .environmentObject(model.manager.trust)
        }
    }
}
