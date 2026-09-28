//
//  SettingsTunnelView.swift
//  Feather (idevice)
//
//  Created by samara on 29.04.2025.
//

import SwiftUI
import NimbleViews
import IDeviceSwift

// MARK: - View
struct TunnelView: View {
	@State private var _isImportingPairingPresenting = false
	
	@State var doesHavePairingFile = false
	@State private var isLocalDevVpnAvailable = false
	
	// MARK: Body
	var body: some View {
		Group {
			Section {
				if #available(iOS 17.4, *) {
				} else {
					_tunnelInfo()
					TunnelHeaderView()
				}
			} footer: {
				if doesHavePairingFile {
					Text(.localized("Seems like you've gotten your hands on your pairing file!"))
				} else {
					Text(.localized("No pairing file found, please import it."))
				}
			}
			
			Section {
				Button {
					_isImportingPairingPresenting = true
				} label: {
					HStack(spacing: 12) {
						SettingsIconBadge(systemImage: "square.and.arrow.down.fill", backgroundColor: .blue)
						Text(.localized("Import Pairing File"))
							.foregroundColor(.primary)
					}
				}
				if #available(iOS 17.4, *) {
				} else {
					Button {
						HeartbeatManager.shared.start(true)
						
						DispatchQueue.global(qos: .userInitiated).async {
							if !HeartbeatManager.shared.checkSocketConnection().isConnected {
								DispatchQueue.main.async {
									UIAlertController.showAlertWithOk(
										title: "Socket",
										message: "Unable to connect to TCP. Make sure you have loopback VPN enabled and you are on WiFi or Airplane mode."
									)
								}
							}
						}
					} label: {
						HStack(spacing: 12) {
							SettingsIconBadge(systemImage: "arrow.counterclockwise", backgroundColor: .orange)
							Text(.localized("Restart Heartbeat"))
								.foregroundColor(.primary)
						}
					}
				}
			}
			
			NBSection(.localized("Help")) {
				Button {
					UIApplication.open("https://github.com/claration/Impactor#pairing-file")
				} label: {
					HStack(spacing: 12) {
						SettingsIconBadge(systemImage: "questionmark.circle.fill", backgroundColor: .purple)
						Text(.localized("Pairing File Guide"))
							.foregroundColor(.primary)
						Spacer()
						Image(systemName: "arrow.up.forward.app")
							.font(.footnote)
							.foregroundColor(Color(UIColor.tertiaryLabel))
					}
				}
				if isLocalDevVpnAvailable {
					Button {
						UIApplication.open("localdevvpn://enable?scheme=feather")
					} label: {
						HStack(spacing: 12) {
							SettingsIconBadge(systemImage: "network", backgroundColor: .green)
							Text(.localized("Connect to LocalDevVPN"))
								.foregroundColor(.primary)
						}
					}
				} else {
					Button {
						UIApplication.open("https://apps.apple.com/us/app/localdevvpn/id6755608044")
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
		.sheet(isPresented: $_isImportingPairingPresenting) {
			FileImporterRepresentableView(
				allowedContentTypes:  [.xmlPropertyList, .plist, .mobiledevicepairing],
				onDocumentsPicked: { urls in
					guard let selectedFileURL = urls.first else { return }
					FR.movePairing(selectedFileURL)
					doesHavePairingFile = true
				}
			)
			.ignoresSafeArea()
		}
		.onAppear {
			doesHavePairingFile = FileManager.default.fileExists(atPath: HeartbeatManager.pairingFile())
				? true
				: false
			if let url = URL(string: "localdevvpn://") {
				isLocalDevVpnAvailable = UIApplication.shared.canOpenURL(url)
			} else {
				isLocalDevVpnAvailable = false
			}
		}
	}
	
	@ViewBuilder
	private func _tunnelInfo() -> some View {
		HStack {
			VStack(alignment: .leading, spacing: 6) {
				Text(.localized("Heartbeat"))
					.font(.headline)
				Text(.localized("The heartbeat is activated in the background, it will restart when the app is re-opened or prompted. If the status below is pulsing, that means its healthy."))
					.font(.subheadline)
					.foregroundStyle(.secondary)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
		}
	}
}
