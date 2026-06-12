import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var manager: TransferManager
    @EnvironmentObject private var trust: TrustStore

    @StateObject private var readiness = ControlReadiness()
    @State private var portText = ""
    @State private var localIP: String?

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gear") }
            devices.tabItem { Label("Devices", systemImage: "checkmark.shield") }
            control.tabItem { Label("Control", systemImage: "keyboard") }
        }
        .frame(width: 460, height: 420)
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
            Section {
                ForEach(TransportStrategy.allCases, id: \.self) { strategy in
                    Toggle(isOn: Binding(
                        get: { settings.isTransportEnabled(strategy) },
                        set: { settings.setTransport(strategy, enabled: $0) }
                    )) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(strategy.label)
                            Text(strategy.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Connection methods")
            } footer: {
                Text("All on by default. Each send tries the enabled methods in order and remembers the one that worked. Turn some off to test a specific method.")
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

    // MARK: Control (KVM) readiness — the MDM feasibility test

    private var control: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    pip(readiness.allReady)
                    Text(readiness.allReady ? "Ready — this Mac can run Control"
                                            : "Not ready — Control can't run here yet")
                        .fontWeight(.medium)
                    Spacer()
                    Button("Re-check") { readiness.refresh() }
                }
            } header: {
                Text("Keyboard / mouse control readiness")
            } footer: {
                Text("Experimental. Run this on each Mac (especially the work laptop). If a toggle is greyed out in System Settings and stays red after Grant, it's blocked by your organization (MDM) — Control can't work there.")
            }

            Section("Permissions") {
                readinessRow("Accessibility", ok: readiness.accessibility,
                             hint: "Inject + consume input") { readiness.requestAccessibility() }
                readinessRow("Input Monitoring", ok: readiness.inputMonitoring,
                             hint: "Capture keyboard & mouse") { readiness.requestInputMonitoring() }
                HStack(spacing: 10) {
                    pip(readiness.eventTapCreatable)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Live event tap")
                        Text("Run manually — this probe can crash a locked-down (MDM) Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Test") { readiness.probeEventTap() }
                }
            }

            if readiness.sandboxed {
                Section {
                    Label("This build is sandboxed; a shipping Control feature would need a non-sandboxed build. A red result here may be the sandbox, not MDM.",
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { readiness.refresh() }
    }

    @ViewBuilder
    private func readinessRow(_ title: String, ok: Bool, hint: String,
                             grant: (() -> Void)? = { }) -> some View {
        HStack(spacing: 10) {
            pip(ok)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !ok, let grant { Button("Grant…", action: grant) }
        }
    }

    private func pip(_ ok: Bool) -> some View {
        Circle().fill(ok ? Color.green : Color.red)
            .frame(width: 11, height: 11)
            .overlay(Circle().strokeBorder(.black.opacity(0.15)))
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
