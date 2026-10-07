import SwiftUI
import NimbleViews

struct ServerView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("Aether.ipFix") private var ipFix = true
    @AppStorage("Aether.serverMethod") private var serverMethod = 1
    @ObservedObject private var setup = LocalServerSetup.shared
    @ObservedObject private var installations = AppInstallationManager.shared

    var body: some View {
        NBList(.localized("Server"), displayMode: .inline) {
            Section {
                Picker(selection: $serverMethod) {
                    Text(.localized("Semi Local")).tag(1)
                    Text(.localized("Fully Local")).tag(0)
                } label: {
                    SettingsRowLabel(.localized("Server Mode"), systemImage: "server.rack", backgroundColor: .blue)
                }
                .disabled(installations.hasPendingInstalls || setup.isSettingUp)
            } footer: {
                Text(.localized("Configures Server installation. Switch between Server and iDevice in Installation settings or from the Device tab."))
            }
            if serverMethod == 1 {
                Section {
                    Toggle(isOn: $ipFix) {
                        SettingsRowLabel(.localized("Only use localhost address"), systemImage: "lifepreserver.fill", backgroundColor: .orange)
                    }
                    .disabled(installations.hasPendingInstalls)
                } footer: {
                    Text(.localized("Uses an online manifest service and serves the app locally over HTTP. No CA setup is required. Localhost avoids Wi-Fi address mismatches."))
                }
            } else {
                Section {
                    LabeledContent(.localized("Local Certificate")) {
                        if setup.isSettingUp || setup.state == .checking {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(statusText).foregroundStyle(.secondary)
                        }
                    }
                    Button {
                        HapticManager.shared.impact()
                        Task { await setup.setUp() }
                    } label: {
                        SettingsRowLabel(setup.state == .setupRequired ? .localized("Set Up") : .localized("Install CA"),
                            systemImage: "checkmark.shield.fill", backgroundColor: .green)
                    }
                    .disabled(installations.hasPendingInstalls || setup.isSettingUp || setup.state == .checking)
                } footer: {
                    Text(.localized("Hosts the manifest and app on this device over HTTPS. Set Up generates a local CA and opens your browser to download its profile. Install it under Settings → General → VPN & Device Management, then enable Aether Local Server CA under General → About → Certificate Trust Settings. Return to Aether to verify setup."))
                }
            }
        }
        .task(id: serverMethod) {
            if serverMethod == 0 { await setup.refresh() }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active, serverMethod == 0 { Task { await setup.refresh() } }
        }
        .alert(.localized("Local Server"), isPresented: Binding(
            get: { scenePhase == .active && setup.error != nil },
            set: { if !$0 { setup.error = nil } }
        )) {
            Button(.localized("OK"), role: .cancel) { setup.error = nil }
        } message: { Text(setup.error ?? "") }
    }

    private var statusText: String {
        switch setup.state {
        case .checking: return .localized("Checking")
        case .setupRequired: return .localized("Setup Required")
        case .trustRequired: return .localized("Trust Required")
        case .ready: return .localized("Ready")
        }
    }
}
