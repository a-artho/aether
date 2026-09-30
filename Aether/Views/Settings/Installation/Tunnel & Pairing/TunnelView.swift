//
//  TunnelView.swift
//  Aether
//

import SwiftUI
import NimbleViews
import IDeviceSwift

struct TunnelView: View {
	@ObservedObject private var connection = DeviceConnectionManager.shared
	@ObservedObject private var embeddedTunnel = EmbeddedTunnelManager.shared
	@State private var isLocalDevVPNAvailable = false

	@State private var draftInterfaceIP: String = ""
	@State private var draftPeerIP: String = ""
	@State private var draftAllowIntermediate: Bool = true
	@State private var validationError: String? = nil
	@State private var isSaving: Bool = false

	var body: some View {
		NBList(.localized("Tunneling"), displayMode: .inline) {
			Section {
				Picker(selection: Binding(
					get: { connection.tunnelMethod },
					set: { connection.setTunnelMethod($0) }
				)) {
					ForEach(DeviceTunnelMethod.allCases) { method in
						Text(method.displayName).tag(method)
					}
				} label: {
					SettingsRowLabel(
						.localized("Tunnel Provider"),
						systemImage: "network",
						backgroundColor: .green
					)
				}
				.disabled(connection.state != .disconnected)
			} footer: {
				Text(
					connection.state == .disconnected
						? .localized("Choose how Aether reaches this device.")
						: .localized("Disconnect the device tunnel before changing providers.")
				)
			}

			switch connection.tunnelMethod {
			case .inApp:
				_inAppControls
			case .localDevVPN:
				_localDevVPNControls
			}
		}
		.onAppear {
			_refreshLocalDevVPNAvailability()
			_syncDraftsFromManager()
			Task { await embeddedTunnel.refresh() }
		}
	}

	@ViewBuilder
	private var _inAppControls: some View {
		Section {
			HStack(spacing: 12) {
				SettingsIconBadge(systemImage: _embeddedStatusIcon, backgroundColor: _embeddedStatusColor)
				VStack(alignment: .leading, spacing: 2) {
					Text(.localized("Aether Tunnel"))
						.foregroundColor(.primary)
					Text(_embeddedStatusText)
						.font(.footnote)
						.foregroundColor(.secondary)
				}
			}

			Toggle(isOn: Binding(
				get: { connection.isAutoTunnelLifecycleEnabled },
				set: { connection.setAutoTunnelLifecycle($0) }
			)) {
				SettingsRowLabel(
					.localized("Auto Start & Stop"),
					systemImage: "bolt.badge.automatic",
					backgroundColor: .blue
				)
			}
		} footer: {
			Text(.localized("Automatically starts tunneling when Aether opens, and stops it when backgrounded if location spoofing is off and no apps are installing."))
		}

		Section {
			HStack {
				SettingsRowLabel(.localized("Tunnel IP"), systemImage: "network", backgroundColor: .blue)
				Spacer()
				TextField("10.7.1.1/32", text: $draftInterfaceIP)
					.multilineTextAlignment(.trailing)
					.autocorrectionDisabled()
					.textInputAutocapitalization(.never)
					.keyboardType(.numbersAndPunctuation)
					.onChange(of: draftInterfaceIP) { _ in _validate() }
					.disabled(connection.state != .disconnected)
			}

			HStack {
				SettingsRowLabel(.localized("Device IP"), systemImage: "iphone", backgroundColor: .purple)
				Spacer()
				TextField("10.7.0.1/32", text: $draftPeerIP)
					.multilineTextAlignment(.trailing)
					.autocorrectionDisabled()
					.textInputAutocapitalization(.never)
					.keyboardType(.numbersAndPunctuation)
					.onChange(of: draftPeerIP) { _ in _validate() }
					.disabled(connection.state != .disconnected)
			}

			Toggle(isOn: $draftAllowIntermediate) {
				SettingsRowLabel(.localized("Allow Intermediate Addresses"), systemImage: "arrow.triangle.branch", backgroundColor: .teal)
			}
			.onChange(of: draftAllowIntermediate) { _ in _validate() }
			.disabled(connection.state != .disconnected)

			if let validationError {
				Text(validationError)
					.font(.caption)
					.foregroundColor(.red)
			}

			if _isDirty {
				Button {
					_saveSettings()
				} label: {
					HStack {
						Spacer()
						if isSaving {
							ProgressView()
								.controlSize(.small)
								.padding(.trailing, 4)
						}
						Text(.localized("Save & Apply"))
							.fontWeight(.semibold)
							.foregroundColor(_isValid ? .accentColor : .secondary)
						Spacer()
					}
				}
				.disabled(!_isValid || isSaving || connection.state != .disconnected)
			}
		} header: {
			Text(.localized("Network Configuration"))
		} footer: {
			Text(.localized("When enabled, non-base CIDR addresses (e.g. 10.7.0.1/24) are accepted and normalized to their network base route. Adjust these addresses if the default 10.7.0.1 subnet conflicts with your Wi-Fi network."))
		}
	}

	@ViewBuilder
	private var _localDevVPNControls: some View {
		Section {
			if isLocalDevVPNAvailable {
				HStack(spacing: 12) {
					SettingsIconBadge(
						systemImage: connection.isConnected ? "checkmark.network" : "network",
						backgroundColor: connection.isConnected ? .green : .orange
					)
					VStack(alignment: .leading, spacing: 2) {
						Text("LocalDevVPN")
							.foregroundColor(.primary)
						Text(_automaticConnectionStatus)
							.font(.footnote)
							.foregroundColor(.secondary)
					}
				}
			} else {
				Button {
					_openLocalDevVPNInAppStore()
				} label: {
					HStack(spacing: 12) {
						SettingsIconBadge(systemImage: "arrow.down.app.fill", backgroundColor: .blue)
						Text(.localized("Download LocalDevVPN"))
							.foregroundColor(.primary)
						Spacer()
						Image(systemName: "arrow.up.forward.app")
							.font(.footnote)
							.foregroundColor(Color(UIColor.tertiaryLabel))
					}
				}
			}

			Toggle(isOn: Binding(
				get: { connection.isAutoTunnelLifecycleEnabled },
				set: { connection.setAutoTunnelLifecycle($0) }
			)) {
				SettingsRowLabel(
					.localized("Auto Start & Stop"),
					systemImage: "bolt.badge.automatic",
					backgroundColor: .blue
				)
			}
		} footer: {
			Text(.localized("Automatically starts tunneling when Aether opens, and stops it when backgrounded if location spoofing is off and no apps are installing."))
		}
	}

	private var _automaticConnectionStatus: String {
		if connection.isUpdating {
			return .localized("Updating connection")
		}
		return connection.isConnected
			? .localized("Connected automatically by iDevice mode")
			: .localized("Managed automatically by iDevice mode")
	}

	private var _embeddedStatusIcon: String {
		switch embeddedTunnel.state {
		case .connected: return "checkmark.shield.fill"
		case .error: return "exclamationmark.shield.fill"
		case .unavailable: return "xmark.shield.fill"
		case .disconnected, .preparing, .connecting, .disconnecting: return "network.badge.shield.half.filled"
		}
	}

	private var _embeddedStatusColor: Color {
		switch embeddedTunnel.state {
		case .connected: return .green
		case .error, .unavailable: return .red
		case .disconnected, .preparing, .connecting, .disconnecting: return .orange
		}
	}

	private var _embeddedStatusText: String {
		switch embeddedTunnel.state {
		case .unavailable: return .localized("Unavailable on this platform")
		case .disconnected: return .localized("Ready to connect")
		case .preparing: return .localized("Preparing configuration")
		case .connecting: return .localized("Connecting")
		case .connected: return .localized("Connected")
		case .disconnecting: return .localized("Disconnecting")
		case .error(let message): return message
		}
	}

	private func _refreshLocalDevVPNAvailability() {
		guard let url = URL(string: "localdevvpn://") else {
			isLocalDevVPNAvailable = false
			return
		}
		isLocalDevVPNAvailable = UIApplication.shared.canOpenURL(url)
	}

	private func _openLocalDevVPNInAppStore() {
		let appStoreURL = URL(string: "itms-apps://apps.apple.com/app/id6755608044")!
		let webURL = URL(string: "https://apps.apple.com/app/id6755608044")!

		#if targetEnvironment(simulator)
		UIApplication.shared.open(webURL, options: [:], completionHandler: nil)
		#else
		if UIApplication.shared.canOpenURL(appStoreURL) {
			UIApplication.shared.open(appStoreURL, options: [:]) { success in
				if !success {
					UIApplication.shared.open(webURL, options: [:], completionHandler: nil)
				}
			}
		} else {
			UIApplication.shared.open(webURL, options: [:], completionHandler: nil)
		}
		#endif
	}

	private var _isValid: Bool {
		validationError == nil
	}

	private var _isDirty: Bool {
		draftInterfaceIP != embeddedTunnel.interfaceAddress ||
		draftPeerIP != embeddedTunnel.peerAddress ||
		draftAllowIntermediate != embeddedTunnel.allowIntermediateAddresses
	}

	private func _syncDraftsFromManager() {
		draftInterfaceIP = embeddedTunnel.interfaceAddress
		draftPeerIP = embeddedTunnel.peerAddress
		draftAllowIntermediate = embeddedTunnel.allowIntermediateAddresses
		_validate()
	}

	private func _validate() {
		do {
			_ = try CIDRValidator.shared.validatePair(
				tunnelIfaceInput: draftInterfaceIP,
				tunnelPeerInput: draftPeerIP,
				allowIntermediateAddresses: draftAllowIntermediate
			)
			validationError = nil
		} catch {
			validationError = error.localizedDescription
		}
	}

	private func _saveSettings() {
		Task {
			isSaving = true
			defer { isSaving = false }
			do {
				try await embeddedTunnel.updateNetworkConfiguration(
					interface: draftInterfaceIP,
					peer: draftPeerIP,
					allowIntermediate: draftAllowIntermediate
				)
				validationError = nil
			} catch {
				validationError = error.localizedDescription
			}
		}
	}

	private func _resetSettings() {
		Task {
			isSaving = true
			defer { isSaving = false }
			do {
				try await embeddedTunnel.resetNetworkConfiguration()
				_syncDraftsFromManager()
				validationError = nil
			} catch {
				validationError = error.localizedDescription
			}
		}
	}
}
