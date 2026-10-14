//
//  SettingsView.swift
//  Aether
//
//  Created by samara on 10.04.2025.
//

import SwiftUI
import NimbleViews
import UIKit

// MARK: - View
struct SettingsView: View {
	enum Presentation { case modal, tab }
	let presentation: Presentation
	init(presentation: Presentation = .modal) { self.presentation = presentation }
	@Environment(\.dismiss) private var dismiss
	@AppStorage("aether.selectedCertUUID") private var _storedSelectedCertUUID: String = ""
	@AppStorage("aether.selectedCert") private var _storedSelectedCert: Int = 0
	@State private var _currentIcon: String? = UIApplication.shared.alternateIconName
	@State private var _settingsPath: [AppTabManager.SettingsPage] = []
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
		NavigationStack(path: $_settingsPath) {
			Form {
				Section { InstallationModePickerRow() }
				Section {
					if let cert = selectedCertificate {
						CertificatesCellView(cert: cert)
					} else {
						Text(.localized("No Certificate"))
							.font(.footnote)
							.foregroundColor(.disabled())
					}
					NavigationLink(value: AppTabManager.SettingsPage.certificates) {
						SettingsRowLabel(.localized("Certificates"), systemImage: "checkmark.seal.fill", backgroundColor: .green)
					}
				}
                
				Section {
					NavigationLink(value: AppTabManager.SettingsPage.signing) {
						SettingsRowLabel(.localized("Signing Options"), systemImage: "signature", backgroundColor: .orange)
					}
					NavigationLink(value: AppTabManager.SettingsPage.archive) {
						SettingsRowLabel(.localized("Archive & Compression"), systemImage: "archivebox.fill", backgroundColor: .cyan)
					}
					NavigationLink(value: AppTabManager.SettingsPage.pairingFile) {
						SettingsRowLabel(.localized("Pairing File"), systemImage: "key.fill", backgroundColor: .purple)
					}
					NavigationLink(value: AppTabManager.SettingsPage.tunnel) {
						SettingsRowLabel(.localized("Tunneling"), systemImage: "network", backgroundColor: .green)
					}
				}

				Section {
					NavigationLink(value: AppTabManager.SettingsPage.appearance) {
						SettingsRowLabel(.localized("Appearance"), systemImage: "paintbrush.fill", backgroundColor: .blue)
					}
				}
                
				Section {
					NavigationLink(value: AppTabManager.SettingsPage.logs) {
						SettingsRowLabel(.localized("Logs"), systemImage: "doc.text.magnifyingglass", backgroundColor: .purple)
					}
					NavigationLink(value: AppTabManager.SettingsPage.reset) {
						SettingsRowLabel(.localized("Reset"), systemImage: "trash.fill", backgroundColor: .red)
					}
				}

				Section {
					Button {
						guard let url = URL(string: "https://github.com/a-artho/Aether") else { return }
						UIApplication.shared.open(url)
					} label: {
						HStack {
							SettingsRowLabel(
								.localized("Source Code"),
								systemImage: "chevron.left.forwardslash.chevron.right",
								backgroundColor: .blue
							)
							Spacer()
							Image(systemName: "arrow.up.right")
								.font(.footnote.weight(.semibold))
								.foregroundStyle(.secondary)
						}
					}
					.buttonStyle(.plain)
				}
			}
			.navigationTitle(String.localized("Settings"))
			.navigationBarTitleDisplayMode(.inline)
			// Native grouped page colors adapt to light/dark mode and presentation elevation.
			.scrollContentBackground(.visible)
			.background(Color(uiColor: .systemGroupedBackground))
			.navigationDestination(for: AppTabManager.SettingsPage.self) { page in
				switch page {
				case .appearance: AppearanceView()
				case .appIcon: AppIconView(currentIcon: $_currentIcon)
				case .certificates: CertificatesView()
				case .signing: ConfigurationView()
				case .archive: ArchiveView()
				case .installation: InstallationView()
				case .serverConfig: EmptyView()
				case .pairingFile: PairingFileView()
				case .tunnel: TunnelView()
				case .logs: LogsView()
				case .reset: ResetView()
				case .root: EmptyView()
				}
			}
			.toolbar {
				if presentation == .modal {
					ToolbarItem(placement: .topBarTrailing) {
						Button {
							dismiss()
						} label: {
							Image(systemName: "xmark")
						}
						.accessibilityLabel(.localized("Close Settings"))
					}
				}
			}
			.onAppear {
				_presentRequestedPageIfNeeded()
				_tabManager.visibleSettingsPage = _settingsPath.last ?? .root
			}
			.onChange(of: _settingsPath) { _, path in
				_tabManager.visibleSettingsPage = path.last ?? .root
			}
			.onChange(of: _tabManager.requestedSettingsPage) { _, _ in
				_presentRequestedPageIfNeeded()
			}
		}
	}

	private func _presentRequestedPageIfNeeded() {
		let ownsPresentation = presentation == .tab
			? _tabManager.usesSettingsTab && _tabManager.selectedTab == .settings
			: !_tabManager.usesSettingsTab && _tabManager.isSettingsPresented
		guard ownsPresentation, let page = _tabManager.requestedSettingsPage else { return }
		_settingsPath = page == .root ? [] : [page]
		_tabManager.requestedSettingsPage = nil
	}
}
