//
//  InstallationView.swift
//  Feather
//
//  Created by samara on 3.06.2025.
//

import SwiftUI
import NimbleViews

// MARK: - View
struct InstallationView: View {
	@AppStorage("Feather.installationMethod") private var _installationMethod: Int = 0
	@AppStorage("Feather.spoofing.simulationMayBeActive") private var _isSpoofingActive = false
	@ObservedObject private var _connection = DeviceConnectionManager.shared
	@State private var _showMethodChangedAlert = false
	@State private var _showStopSpoofingAlert = false

	private let _installationMethods: [String] = [
		.localized("Server"),
		.localized("idevice")
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
			} footer: {
				Text(.localized("Server (Recommended):\nUses a locally hosted server and itms-services:// to install applications.\n\nIDevice (advanced):\nUses a VPN and a pairing file. Writes to AFC and manually calls installd, while monitoring install progress by using a callback\nAdvantage: It is very reliable, does not need SSL certificates or a externally hosted server. Rather, works similarly to a computer."))
			}
			
			if _installationMethod == 0 {
				ServerView(embedInList: false)
			}
		}
		.alert(.localized("Advanced Installation Method"), isPresented: $_showMethodChangedAlert) {
			Button(.localized("Switch Back"), role: .destructive) {
				_selectInstallationMethod(0)
			}
			Button(.localized("OK"), role: .cancel) {}
		} message: {
			Text(.localized("idevice warning"))
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
