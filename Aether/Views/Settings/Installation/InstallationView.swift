//
//  InstallationView.swift
//  Aether
//

import SwiftUI
import NimbleViews

struct InstallationView: View {
	@AppStorage("Aether.installationMethod") private var installationMethod = 0
	@ObservedObject private var connection = DeviceConnectionManager.shared
	@ObservedObject private var installationManager = AppInstallationManager.shared
	@State private var showStopSpoofingAlert = false
	@State private var isSpoofingPresented = false

	var body: some View {
		NBList(.localized("Installation"), displayMode: .inline) {
			Section {
				Picker(selection: Binding(
					get: { installationMethod },
					set: { selectInstallationMethod($0) }
				)) {
					Text(.localized("Server")).tag(0)
					Text(.localized("iDevice")).tag(1)
				} label: {
					SettingsRowLabel(
						.localized("Mode"),
						systemImage: installationMethod == 1 ? "iphone" : "server.rack",
						backgroundColor: installationMethod == 1 ? .purple : .blue,
						iconSize: installationMethod == 1 ? 16 : 14
					)
				}
				.pickerStyle(.menu)
				.disabled(installationManager.hasPendingInstalls)
			} footer: {
				Text(installationManager.hasPendingInstalls
					? .localized("Installation mode cannot change while installs are active or queued.")
					: .localized("Server installs through a locally hosted server. iDevice installs directly using a tunnel and pairing file."))
			}

			Section(.localized("iDevice")) {
				NavigationLink(destination: TunnelView()) {
					SettingsRowLabel(.localized("Tunneling"), systemImage: "network", backgroundColor: .green)
				}
				NavigationLink(destination: PairingFileView()) {
					SettingsRowLabel(.localized("Pairing File"), systemImage: "key.fill", backgroundColor: .purple)
				}
			}

			Section(.localized("Server")) {
				NavigationLink(destination: ServerView()) {
					SettingsRowLabel(.localized("Server"), systemImage: "server.rack", backgroundColor: .blue)
				}
			}
		}
		.alert(.localized("Stop Spoofing First"), isPresented: $showStopSpoofingAlert) {
			Button(.localized("Open Spoofing")) { isSpoofingPresented = true }
			Button(.localized("Cancel"), role: .cancel) {}
		} message: {
			Text(.localized("Stop the simulated location before switching to Server mode."))
		}
		.sheet(isPresented: $isSpoofingPresented) {
			SpoofingEntryView()
		}
	}

	private func selectInstallationMethod(_ method: Int) {
		guard method != installationMethod, !installationManager.hasPendingInstalls else { return }
		guard connection.setInstallationMode(method) else {
			showStopSpoofingAlert = true
			return
		}
		HapticManager.shared.selection()
	}
}
