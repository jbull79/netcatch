import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var manager: TransferManager
    @EnvironmentObject private var trust: TrustStore

    @State private var portText = ""
    @State private var localIP: String?

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gear") }
            devices.tabItem { Label("Devices", systemImage: "checkmark.shield") }
        }
        .frame(width: 460, height: 360)
        .onAppear {
            portText = String(settings.port)
            localIP = LocalNetwork.ipv4Address()
        }
    }

    private var general: some View {
        Form {
            Section("This device") {
                TextField("Name", text: $settings.deviceName)
                HStack {
                    TextField("Port", text: $portText)
                        .frame(width: 90)
                    Button("Apply") {
                        if let p = UInt16(portText) { settings.port = p }
                        manager.restartServices()
                    }
                }
                if let ip = localIP {
                    LabeledContent("Address") {
                        Text("\(ip):\(settings.port)")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            Section("Receiving") {
                HStack {
                    Text("Save to")
                    Spacer()
                    Text(settings.defaultSaveDirectory.lastPathComponent)
                        .foregroundStyle(.secondary)
                    Button("Choose…", action: chooseFolder)
                }
                Toggle("Auto-accept from known devices", isOn: $settings.autoAcceptTrusted)
            }
            Section("Sending") {
                Toggle("Compress by default", isOn: $settings.compressByDefault)
            }
        }
        .formStyle(.grouped)
    }

    private var devices: some View {
        VStack(alignment: .leading) {
            if trust.known.isEmpty {
                ContentUnavailableView("No known devices",
                                       systemImage: "shield",
                                       description: Text("Devices you accept transfers from appear here."))
            } else {
                List {
                    ForEach(trust.known.sorted(by: { $0.value < $1.value }), id: \.key) { fingerprint, name in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(name)
                                Text(fingerprint).font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Forget") { trust.forget(fingerprint) }
                                .buttonStyle(.link)
                        }
                    }
                }
            }
        }
        .padding()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            settings.setSaveDirectory(url)
        }
    }
}
