import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var manager: TransferManager
    @EnvironmentObject private var receiver: ReceiverServer
    @EnvironmentObject private var settings: AppSettings

    enum Section: String, CaseIterable, Identifiable {
        case send = "Send"
        case activity = "Activity"
        case history = "History"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .send: return "paperplane.fill"
            case .activity: return "arrow.up.arrow.down.circle.fill"
            case .history: return "clock.fill"
            }
        }
    }

    @State private var selection: Section = .send

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
            .safeAreaInset(edge: .bottom) { statusFooter }
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(item: Binding(get: { manager.pendingRequest }, set: { _ in })) { request in
            AcceptSheet(request: request)
                .environmentObject(manager)
                .interactiveDismissDisabled(true)
        }
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .send: SendView()
        case .activity: ActivityView()
        case .history: HistoryView()
        }
    }

    private var statusFooter: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(receiver.isRunning ? Color.green : Color.orange)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(settings.deviceName)
                    .font(.caption).fontWeight(.medium)
                    .lineLimit(1)
                Text(receiver.isRunning ? "Discoverable" : "Offline")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(.thinMaterial)
    }
}
