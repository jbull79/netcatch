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
        // Handle netcatch:// links (v2) — for now, treat file URLs as a send request.
        let fileURLs = urls.filter { $0.isFileURL }
        if !fileURLs.isEmpty {
            AppModel.shared.queueSend(urls: fileURLs)
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
