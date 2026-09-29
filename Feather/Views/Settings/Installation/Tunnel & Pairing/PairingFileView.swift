//
//  PairingFileView.swift
//  Feather
//

import SwiftUI
import NimbleViews
import IDeviceSwift

struct PairingFileView: View {
	@State private var _isImportingPairingPresenting = false
	@State private var _isOnDevicePairingPresenting = false
	@ObservedObject private var _onDevicePairing = OnDevicePairingManager.shared

	@State private var _activePairingRecordSource: HeartbeatManager.PairingRecordSource?

	var body: some View {
		NBList(.localized("Pairing File"), displayMode: .inline) {
			Section {
				HStack(spacing: 12) {
					SettingsIconBadge(
						systemImage: _activePairingRecordSource == nil ? "key.slash" : "key.fill",
						backgroundColor: _activePairingRecordSource == nil ? .gray : .green
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

			NBSection(.localized("Help")) {
				Button {
					UIApplication.open("https://github.com/claration/Impactor#pairing-file")
				} label: {
					HStack {
						SettingsRowLabel(
							.localized("Pairing File Guide"),
							systemImage: "questionmark.circle.fill",
							backgroundColor: .purple
						)
						Spacer()
						Image(systemName: "arrow.up.forward.app")
							.font(.footnote)
							.foregroundColor(Color(UIColor.tertiaryLabel))
					}
				}
			}
		}
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
		.onChange(of: _onDevicePairing.state) { state in
			if case .completed = state {
				_refreshPairingState()
			}
		}
	}

	private var _pairingStatus: String {
		switch _activePairingRecordSource {
		case .onDevice:
			return .localized("On-device pairing is active")
		case .imported:
			return .localized("Imported pairing file is active")
		case .none:
			return .localized("No pairing file")
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
		HeartbeatManager.useOnDevicePairingFile()
		_switchPairingRecord()
	}

	private func _useImportedPairingRecord() {
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
		_activePairingRecordSource = HeartbeatManager.activePairingRecordSource()
	}
}
