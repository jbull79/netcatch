import SwiftUI
import UniformTypeIdentifiers

struct SendView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var manager: TransferManager
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var discovery: DiscoveryService

    @State private var compress = true
    @State private var isTargeted = false
    @State private var showImporter = false
    @State private var manualHost = ""
    @State private var manualPort = ""
    @State private var localIP: String?

    private var urls: [URL] { model.pendingSendURLs }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                dropArea
                if !urls.isEmpty { selectedList; options }
                peersSection
                manualSection
            }
            .padding(22)
        }
        .navigationTitle("Send")
        .onAppear {
            compress = settings.compressByDefault
            localIP = LocalNetwork.ipv4Address()
            if manualPort.isEmpty { manualPort = String(settings.port) }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case let .success(picked) = result { model.pendingSendURLs = picked }
        }
    }

    // MARK: Drop area

    private var dropArea: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.up.fill")
                .font(.system(size: 42))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
            Text("Drag files or folders here")
                .font(.headline)
            Text("or")
                .foregroundStyle(.secondary)
            Button("Choose…") { showImporter = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(isTargeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
        )
        .onDrop(of: [.item], isTargeted: $isTargeted) { providers in
            Task { @MainActor in
                let urls = await DropMaterializer.materialize(providers)
                if !urls.isEmpty { model.pendingSendURLs = urls }
            }
            return true
        }
    }

    // MARK: Selected items

    private var selectedList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Selected").font(.headline)
                Spacer()
                Button("Clear") { model.pendingSendURLs = [] }
                    .buttonStyle(.link)
            }
            ForEach(urls, id: \.self) { url in
                HStack(spacing: 10) {
                    Image(systemName: url.hasDirectoryPath ? "folder.fill" : "doc.fill")
                        .foregroundStyle(.tint)
                    Text(url.lastPathComponent).lineLimit(1)
                    Spacer()
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
            }
        }
    }

    private var options: some View {
        Toggle(isOn: $compress) {
            VStack(alignment: .leading) {
                Text("Compress before sending")
                Text("Folders are zipped; already-compressed files are skipped automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
    }

    // MARK: Peers

    private var peersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Send to").font(.headline)
            if discovery.peers.isEmpty {
                Label("Looking for nearby devices…", systemImage: "wifi")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(discovery.peers) { peer in
                    peerRow(peer)
                }
            }
        }
    }

    private func peerRow(_ peer: Peer) -> some View {
        Button {
            manager.send(urls: urls, to: peer, compress: compress)
            model.pendingSendURLs = []
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "desktopcomputer")
                Text(peer.name)
                Spacer()
                Image(systemName: "paperplane.fill").foregroundStyle(.tint)
            }
            .contentShape(Rectangle())
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .disabled(urls.isEmpty)
        .opacity(urls.isEmpty ? 0.5 : 1)
    }

    private var manualSection: some View {
        DisclosureGroup("Send to an IP address") {
            VStack(alignment: .leading, spacing: 6) {
                if let ip = localIP {
                    Text("Your Mac: \(ip):\(settings.port) — others can send to you here. The other Mac listens on its own port (default \(settings.port)).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    TextField("Host (e.g. 192.168.1.20)", text: $manualHost)
                    TextField("Port", text: $manualPort)
                        .frame(width: 80)
                    Button("Send") {
                        let port = UInt16(manualPort) ?? settings.port
                        if let peer = Peer.manual(host: manualHost, port: port) {
                            manager.send(urls: urls, to: peer, compress: compress)
                            model.pendingSendURLs = []
                        }
                    }
                    .disabled(urls.isEmpty || manualHost.isEmpty)
                }
                .textFieldStyle(.roundedBorder)
            }
            .padding(.top, 6)
        }
        .font(.headline)
    }
}
