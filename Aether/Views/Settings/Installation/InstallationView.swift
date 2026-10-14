//
//  InstallationView.swift
//  Aether
//
//  Created by samara on 3.06.2025.
//

import SwiftUI
import NimbleViews

// MARK: - View
struct InstallationView: View {
	@AppStorage("Aether.installationMethod") private var _installationMethod: Int = 0
	@AppStorage("Aether.spoofing.simulationMayBeActive") private var _isSpoofingActive = false
	@ObservedObject private var _connection = DeviceConnectionManager.shared
	@ObservedObject private var _installationManager = AppInstallationManager.shared
	@State private var _showMethodChangedAlert = false
	@State private var _showStopSpoofingAlert = false

	private let _installationMethods: [String] = [
		.localized("Server"),
		.localized("Local")
	]
	
	// MARK: Body
	var body: some View {
		NBList(.localized("Installation"), displayMode: .inline) {
			Section {
				Picker(selection: Binding(
					get: { _installationMethod },
					set: { _selectInstallationMethod($0) }
				)) {
					ForEach(_installationMethods.indices, id: \.description) { index in
						Text(_installationMethods[index]).tag(index)
					}
				} label: {
					SettingsRowLabel(
						.localized("Installation Type"),
						systemImage: _installationMethod == 1 ? "iphone" : "server.rack",
						backgroundColor: _installationMethod == 1 ? .purple : .blue,
						iconSize: _installationMethod == 1 ? 16 : 14
					)
				}
				.disabled(_installationManager.hasPendingInstalls)
			} footer: {
				Text(_installationManager.hasPendingInstalls
					? .localized("Installation type cannot change while an install is in progress.")
					: .localized("Server (Recommended):\nUses a locally hosted server and itms-services:// to install applications.\n\nLocal:\nUses a tunnel and pairing file to install directly to your device. It does not require SSL certificates or an externally hosted server."))
			}
			
		}
		.alert(.localized("Local Installation"), isPresented: $_showMethodChangedAlert) {
			Button(.localized("Switch Back"), role: .destructive) {
				_selectInstallationMethod(0)
			}
			Button(.localized("OK"), role: .cancel) {}
		} message: {
			Text(.localized("Local installs use a tunnel and a pairing file to install directly to your device."))
		}
		.alert(.localized("Stop Spoofing First"), isPresented: $_showStopSpoofingAlert) {
			Button(.localized("OK"), role: .cancel) {}
		} message: {
			Text(.localized("Stop the simulated location before switching to Server mode."))
		}


		.animation(.default, value: _installationMethod)
	}

	private func _selectInstallationMethod(_ method: Int) {
		guard method != _installationMethod else { return }
		if method == 0 && _isSpoofingActive {
			_showStopSpoofingAlert = true
			return
		}
		guard _connection.setInstallationMode(method) else {
			_showStopSpoofingAlert = true
			return
		}
		if method == 1 {
			_showMethodChangedAlert = true
		}
	}
}

/// All mode controls use the connection manager's active-job and spoofing guards.
struct InstallationModePickerRow: View {
	@AppStorage("Aether.installationMethod") private var method = 0
	@ObservedObject private var installations = AppInstallationManager.shared
	@State private var blocked = false

	var body: some View {
		Picker(selection: Binding(get: { method }, set: { value in
			guard value != method else { return }
			if DeviceConnectionManager.shared.setInstallationMode(value) { HapticManager.shared.selection() }
			else { blocked = true }
		})) {
			Text(String.localized("Server")).tag(0)
			Text(String.localized("Local")).tag(1)
		} label: {
			SettingsRowLabel(.localized("Installation Mode"), systemImage: "arrow.left.arrow.right", backgroundColor: .purple)
		}
		.pickerStyle(.menu)
		.tint(.secondary)
		.disabled(installations.hasPendingInstalls)
		.alert(.localized("Stop Spoofing First"), isPresented: $blocked) {
			Button(.localized("OK"), role: .cancel) {}
		} message: { Text(.localized("Stop the simulated location before switching to Server mode.")) }
	}
}
