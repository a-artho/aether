//
//  TunnelView.swift
//  Aether
//

import SwiftUI
import NimbleViews
import IDeviceSwift

struct TunnelView: View {
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@ObservedObject private var connection = DeviceConnectionManager.shared
	@ObservedObject private var embeddedTunnel = EmbeddedTunnelManager.shared
	@ObservedObject private var installations = AppInstallationManager.shared
	@ObservedObject private var pairing = OnDevicePairingManager.shared
	@AppStorage("Aether.spoofing.simulationMayBeActive") private var isSpoofingActive = false
	@ObservedObject private var cellularAssist = CellularAssistManager.shared
	@State private var isLocalDevVPNAvailable = false

	@State private var draftInterfaceIP: String = ""
	@State private var draftPeerIP: String = ""
	@State private var draftAllowIntermediate: Bool = true
	@State private var validationError: String? = nil
	@State private var isSaving: Bool = false
	@State private var networkConfigurationExpanded = false

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
				.disabled(connection.isUpdating || AppMaintenanceGuard.pairingBlockReason != nil)
			} footer: {
				Text(.localized("Choose how Aether reaches this device."))
			}

			switch connection.tunnelMethod {
			case .inApp:
				_inAppControls
			case .localDevVPN:
				_localDevVPNControls
				_automationControls
			}
		}
		.aetherAmbientScrollBackground(base: .grouped)
		.onAppear {
			_refreshLocalDevVPNAvailability()
			_syncDraftsFromManager()
			Task { await connection.refresh() }
		}
	}

	@ViewBuilder
	private var _inAppControls: some View {
		Section {
			Button {
				withAnimation(reduceMotion ? nil : .snappy) {
					networkConfigurationExpanded.toggle()
				}
			} label: {
				HStack(spacing: 12) {
					SettingsIconBadge(systemImage: _embeddedStatusIcon, backgroundColor: _embeddedStatusColor)
					VStack(alignment: .leading, spacing: 2) {
						Text(.localized("Aether Tunnel"))
							.foregroundStyle(.primary)
						Text(_embeddedStatusText)
							.font(.footnote)
							.foregroundStyle(.secondary)
					}
					Spacer()
					Image(systemName: "chevron.right")
						.font(.footnote.weight(.semibold))
						.foregroundStyle(.tertiary)
						.rotationEffect(.degrees(networkConfigurationExpanded ? 90 : 0))
						.accessibilityHidden(true)
				}
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.accessibilityValue(networkConfigurationExpanded ? String.localized("Expanded") : String.localized("Collapsed"))

			if networkConfigurationExpanded {
				HStack {
					SettingsRowLabel(.localized("Tunnel IP"), systemImage: "network", backgroundColor: .blue)
					Spacer()
					TextField("10.7.1.1/32", text: $draftInterfaceIP)
						.multilineTextAlignment(.trailing)
						.autocorrectionDisabled()
						.textInputAutocapitalization(.never)
						.keyboardType(.numbersAndPunctuation)
						.onChange(of: draftInterfaceIP) { _, _ in _validate() }
						.disabled(connection.isUpdating || AppMaintenanceGuard.pairingBlockReason != nil)
				}

				HStack {
					SettingsRowLabel(.localized("Device IP"), systemImage: "iphone", backgroundColor: .purple)
					Spacer()
					TextField("10.7.0.1/32", text: $draftPeerIP)
						.multilineTextAlignment(.trailing)
						.autocorrectionDisabled()
						.textInputAutocapitalization(.never)
						.keyboardType(.numbersAndPunctuation)
						.onChange(of: draftPeerIP) { _, _ in _validate() }
						.disabled(connection.isUpdating || AppMaintenanceGuard.pairingBlockReason != nil)
				}

				Toggle(isOn: $draftAllowIntermediate) {
					SettingsRowLabel(.localized("Allow Intermediate Addresses"), systemImage: "arrow.triangle.branch", backgroundColor: .teal)
				}
				.onChange(of: draftAllowIntermediate) { _, _ in _validate() }
				.disabled(connection.isUpdating || AppMaintenanceGuard.pairingBlockReason != nil)

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
					.disabled(!_isValid || isSaving || connection.state != .disconnected || connection.isUpdating)
				}
				Text(.localized("When enabled, non-base CIDR addresses (e.g. 10.7.0.1/24) are accepted and normalized to their network base route. Adjust these addresses if the default 10.7.0.1 subnet conflicts with your Wi-Fi network."))
					.font(.footnote)
					.foregroundStyle(.secondary)
			}
		}

		_automationControls
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

		}
	}

	@ViewBuilder
	private var _automationControls: some View {
		Section {
			Toggle(isOn: Binding(
				get: { connection.isConnectAutomaticallyEnabled },
				set: { connection.setConnectAutomatically($0) }
			)) {
				SettingsRowLabel(.localized("Connect Automatically"), systemImage: "bolt.badge.automatic", backgroundColor: .blue)
			}
			Toggle(isOn: Binding(
				get: { connection.isDisconnectWhenIdleEnabled },
				set: { connection.setDisconnectWhenIdle($0) }
			)) {
				SettingsRowLabel(.localized("Disconnect When Idle"), systemImage: "moon", backgroundColor: .indigo)
			}
			.disabled(connection.tunnelMethod == .localDevVPN)
		} header: {
			Text(.localized("Automation"))
		} footer: {
			Text(.localized("Connect Automatically connects when Aether opens or returns to the foreground in iDevice mode. Disconnect When Idle disconnects when Aether enters the background and no device operation needs the tunnel."))
		}

		Section {
			Toggle(isOn: Binding(
				get: { cellularAssist.isEnabled },
				set: { cellularAssist.requestEnabled($0) }
			)) {
				SettingsRowLabel(.localized("Cellular Assist"), systemImage: "antenna.radiowaves.left.and.right", backgroundColor: .orange)
			}
			.disabled(cellularAssist.isBusy || connection.tunnelMethod != .inApp)
		} footer: {
			Text(.localized("With In-App tunneling on cellular without Wi-Fi, briefly turns Mobile Data off to connect to your device, then restores it. Add the exported Aether Cellular shortcut to Shortcuts and choose Always Allow when prompted."))
		}
	}

	private var _automaticConnectionStatus: String {
		if connection.isUpdating {
			return .localized("Updating connection")
		}
		return connection.isConnected
			? .localized("Connected automatically by Local mode")
			: .localized("Managed automatically by Local mode")
	}

	private var _embeddedStatusIcon: String {
		if connection.requiresInAppTunnelSetup {
			return "network.badge.shield.half.filled"
		}
		switch embeddedTunnel.state {
		case .connected: return "checkmark.shield.fill"
		case .error: return "exclamationmark.shield.fill"
		case .unavailable: return "xmark.shield.fill"
		case .disconnected, .preparing, .connecting, .disconnecting: return "network.badge.shield.half.filled"
		}
	}

	private var _embeddedStatusColor: Color {
		if connection.requiresInAppTunnelSetup {
			return .orange
		}
		switch embeddedTunnel.state {
		case .connected: return .green
		case .error, .unavailable: return .red
		case .disconnected, .preparing, .connecting, .disconnecting: return .orange
		}
	}

	private var _embeddedStatusText: String {
		if connection.requiresInAppTunnelSetup {
			return .localized("Setup Required")
		}
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
				try await connection.updateInAppNetworkConfiguration(
					interface: draftInterfaceIP,
					peer: draftPeerIP,
					allowIntermediate: draftAllowIntermediate
				)
				validationError = nil
			} catch is CancellationError {
				// A newer lifecycle operation owns the connection now.
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
				try await connection.updateInAppNetworkConfiguration(
					interface: EmbeddedTunnelManager.defaultInterfaceAddress,
					peer: EmbeddedTunnelManager.defaultPeerAddress,
					allowIntermediate: EmbeddedTunnelManager.defaultAllowIntermediate)
				_syncDraftsFromManager()
				validationError = nil
			} catch is CancellationError {
				_syncDraftsFromManager()
			} catch {
				validationError = error.localizedDescription
			}
		}
	}
}
