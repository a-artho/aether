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
					NavigationLink(destination: AppearanceView()) {
						SettingsRowLabel(.localized("Appearance"), systemImage: "paintbrush.fill", backgroundColor: .blue)
					}
					NavigationLink(destination: AppIconView(currentIcon: $_currentIcon)) {
						SettingsRowLabel(.localized("App Icon"), systemImage: "app.badge.fill", backgroundColor: .indigo)
					}
				}
                
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
					NavigationLink(destination: InstallationView()) {
						SettingsRowLabel(.localized("Installation"), systemImage: "arrow.down.circle.fill", backgroundColor: .blue)
					}
					NavigationLink(destination: PairingFileView()) {
						SettingsRowLabel(.localized("Pairing File"), systemImage: "key.fill", backgroundColor: .purple)
					}
				}
                
				Section {
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
					case .installation: InstallationView()
					case .pairingFile: PairingFileView()
					case .reset: ResetView()
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
			_activeSettingsPage = page
			_tabManager.requestedSettingsPage = nil
		}
	}
}
