//
//  SettingsView.swift
//  Feather
//
//  Created by samara on 10.04.2025.
//

import SwiftUI
import NimbleViews
import UIKit

// MARK: - View
struct SettingsView: View {
	@Environment(\.dismiss) private var dismiss
	@AppStorage("feather.selectedCertUUID") private var _storedSelectedCertUUID: String = ""
	@AppStorage("feather.selectedCert") private var _storedSelectedCert: Int = 0
	@State private var _currentIcon: String? = UIApplication.shared.alternateIconName
	@State private var _activeSettingsPage: AppTabManager.SettingsPage? = nil
	@ObservedObject private var _tabManager = AppTabManager.shared
	
	// MARK: Fetch
	@FetchRequest(
		entity: CertificatePair.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)],
		animation: .snappy
	) private var _certificates: FetchedResults<CertificatePair>
	
	private var selectedCertificate: CertificatePair? {
		if !_storedSelectedCertUUID.isEmpty {
			if let match = _certificates.first(where: { $0.uuid == _storedSelectedCertUUID }) {
				return match
			}
		}
		guard
			_storedSelectedCert >= 0,
			_storedSelectedCert < _certificates.count
		else {
			return nil
		}
		return _certificates[_storedSelectedCert]
	}
	// MARK: Body
	var body: some View {
		NBNavigationView(.localized("Settings"), displayMode: .inline) {
			Form {
				Section {
					if let cert = selectedCertificate {
						CertificatesCellView(cert: cert)
					} else {
						Text(.localized("No Certificate"))
							.font(.footnote)
							.foregroundColor(.disabled())
					}
					NavigationLink(destination: CertificatesView()) {
						SettingsRowLabel(.localized("Certificates"), systemImage: "checkmark.seal.fill", backgroundColor: .green)
					}
				}
                
				Section {
					NavigationLink(destination: ConfigurationView()) {
						SettingsRowLabel(.localized("Signing Options"), systemImage: "signature", backgroundColor: .orange)
					}
					NavigationLink(destination: ArchiveView()) {
						SettingsRowLabel(.localized("Archive & Compression"), systemImage: "archivebox.fill", backgroundColor: .cyan)
					}
					NavigationLink(destination: PairingFileView()) {
						SettingsRowLabel(.localized("Pairing File"), systemImage: "key.fill", backgroundColor: .purple)
					}
					NavigationLink(destination: TunnelView()) {
						SettingsRowLabel(.localized("Tunneling"), systemImage: "network", backgroundColor: .green)
					}
					NavigationLink(destination: ServerView()) {
						SettingsRowLabel(.localized("Server Config"), systemImage: "server.rack", backgroundColor: .blue)
					}
				}

				Section {
					NavigationLink(destination: AppearanceView()) {
						SettingsRowLabel(.localized("Appearance"), systemImage: "paintbrush.fill", backgroundColor: .blue)
					}
				}
                
				Section {
					NavigationLink(destination: LogsView()) {
						SettingsRowLabel(.localized("Logs"), systemImage: "doc.text.magnifyingglass", backgroundColor: .purple)
					}
					NavigationLink(destination: ResetView()) {
						SettingsRowLabel(.localized("Reset"), systemImage: "trash.fill", backgroundColor: .red)
					}
				}
			}
			.navigationDestination(isPresented: Binding(
				get: { _activeSettingsPage != nil },
				set: { if !$0 { _activeSettingsPage = nil } }
			)) {
				if let page = _activeSettingsPage {
					switch page {
					case .appearance: AppearanceView()
					case .appIcon: AppIconView(currentIcon: $_currentIcon)
					case .certificates: CertificatesView()
					case .signing: ConfigurationView()
					case .archive: ArchiveView()
					case .serverConfig, .installation: ServerView()
					case .pairingFile: PairingFileView()
					case .tunnel: TunnelView()
					case .logs: LogsView()
					case .reset: ResetView()
					case .root: EmptyView()
					}
				}
			}
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Button {
						dismiss()
					} label: {
						Image(systemName: "xmark")
					}
					.accessibilityLabel(.localized("Close Settings"))
				}
			}
			.onAppear {
				_presentRequestedPageIfNeeded()
			}
			.onChange(of: _tabManager.requestedSettingsPage) { _ in
				_presentRequestedPageIfNeeded()
			}
		}
	}

	private func _presentRequestedPageIfNeeded() {
		guard let page = _tabManager.requestedSettingsPage else { return }
		DispatchQueue.main.async {
			if page == .root {
				_activeSettingsPage = nil
			} else {
				_activeSettingsPage = page
			}
			_tabManager.requestedSettingsPage = nil
		}
	}
}
