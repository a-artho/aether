//
//  PairingFileView.swift
//  Aether
//

import SwiftUI
import NimbleViews
import IDeviceSwift

struct PairingFileView: View {
	@State private var _isImportingPairingPresenting = false
	@State private var _isOnDevicePairingPresenting = false
	@ObservedObject private var _installations = AppInstallationManager.shared
	@AppStorage("Aether.spoofing.simulationMayBeActive") private var _spoofingActive = false
	@ObservedObject private var _connection = DeviceConnectionManager.shared
	@ObservedObject private var _onDevicePairing = OnDevicePairingManager.shared

	@State private var _activePairingRecordSource: HeartbeatManager.PairingRecordSource?

	var body: some View {
		NBList(.localized("Pairing File"), displayMode: .inline) {
			Section {
				HStack(spacing: 12) {
					SettingsIconBadge(
						systemImage: _activePairingRecordSource == nil ? "key.slash" : "key.fill",
						backgroundColor: _connection.isConnected && _connection.pairingVerification.status == .verified ? .green : .gray
					)

					VStack(alignment: .leading, spacing: 2) {
						Text(.localized("Pairing File"))
							.foregroundColor(.primary)
						Text(_pairingStatus)
							.font(.footnote)
							.foregroundColor(.secondary)
					}
				}
			}

			Section {
				Button {
					_onDevicePairing.begin()
					_isOnDevicePairingPresenting = true
				} label: {
					_pairingActionLabel(
						title: .localized("On-Device Pairing"),
						icon: "iphone.and.arrow.forward",
						color: .purple,
						isEnabled: OnDevicePairingManager.isSupported
					)
				}
				.disabled(!OnDevicePairingManager.isSupported)

				if HeartbeatManager.hasOnDevicePairingFile(), _activePairingRecordSource != .onDevice {
					Button {
						_useOnDevicePairingRecord()
					} label: {
						_pairingActionLabel(
							title: .localized("Use On-Device Pairing"),
							icon: "checkmark.icloud.fill",
							color: .green
						)
					}
				}

				if HeartbeatManager.hasImportedPairingFile(), _activePairingRecordSource != .imported {
					Button {
						_useImportedPairingRecord()
					} label: {
						_pairingActionLabel(
							title: .localized("Use Imported Pairing File"),
							icon: "doc.badge.checkmark",
							color: .orange
						)
					}
				}

				Button {
					_isImportingPairingPresenting = true
				} label: {
					_pairingActionLabel(
						title: .localized("Import Pairing File"),
						icon: "square.and.arrow.down.fill",
						color: .blue
					)
				}
			}

		}
		.disabled(AppMaintenanceGuard.pairingBlockReason != nil)
		.sheet(isPresented: $_isImportingPairingPresenting) {
			FileImporterRepresentableView(
				allowedContentTypes: [.xmlPropertyList, .plist, .mobiledevicepairing],
				onDocumentsPicked: { urls in
					guard let selectedFileURL = urls.first else { return }
					FR.movePairing(selectedFileURL)
					_refreshPairingState()
				}
			)
			.ignoresSafeArea()
		}
		.sheet(isPresented: Binding(
			get: { _isOnDevicePairingPresenting || _onDevicePairing.isActive },
			set: {
				_isOnDevicePairingPresenting = $0
				if !$0 && _onDevicePairing.isActive {
					_onDevicePairing.cancel()
				}
			}
		)) {
			OnDevicePairingView()
				.onDisappear {
					_refreshPairingState()
				}
		}
		.onAppear {
			_refreshPairingState()
		}
		.onChange(of: _connection.pairingVerification) { _, _ in
			_refreshPairingState()
		}
		.onChange(of: _onDevicePairing.state) { _, state in
			if case .completed = state {
				_refreshPairingState()
			}
		}
	}

	private var _pairingStatus: String {
		switch _activePairingRecordSource {
		case .onDevice:
			return _verificationStatus(onDevice: true)
		case .imported:
			return _verificationStatus(onDevice: false)
		case .none:
			return .localized("No pairing file")
		}
	}

	private func _verificationStatus(onDevice: Bool) -> String {
		switch _connection.pairingVerification.status {
		case .verified where _connection.isConnected:
			return onDevice ? .localized("On-device pairing verified") : .localized("Imported pairing verified")
		case .checking:
			return .localized("Checking pairing…")
		case .unableToVerify:
			return .localized("Pairing saved — unable to verify")
		default:
			return onDevice ? .localized("On-device pairing saved — unverified") : .localized("Imported pairing saved — unverified")
		}
	}

	private func _pairingActionLabel(title: String, icon: String, color: Color, isEnabled: Bool = true) -> some View {
		SettingsRowLabel(
			title,
			systemImage: icon,
			backgroundColor: isEnabled ? color : Color(UIColor.systemGray4),
			textColor: isEnabled ? .primary : .secondary
		)
	}

	private func _useOnDevicePairingRecord() {
		guard AppMaintenanceGuard.allowPairingChange() else { return }
		HeartbeatManager.useOnDevicePairingFile()
		_switchPairingRecord()
	}

	private func _useImportedPairingRecord() {
		guard AppMaintenanceGuard.allowPairingChange() else { return }
		HeartbeatManager.useImportedPairingFile()
		_switchPairingRecord()
	}

	private func _switchPairingRecord() {
		HeartbeatManager.shared.resetRSDTunnel()
		_refreshPairingState()
		Task {
			await DeviceConnectionManager.shared.refresh()
		}
	}

	private func _refreshPairingState() {
		_connection.refreshStoredPairingState()
		_activePairingRecordSource = HeartbeatManager.activePairingRecordSource()
	}
}
