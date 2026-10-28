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
	@AppStorage("aether.selectedCertUUID") private var _storedSelectedCertUUID: String = ""
	@AppStorage("aether.selectedCert") private var _storedSelectedCert: Int = 0
	@ObservedObject private var connection = DeviceConnectionManager.shared
	@AppStorage("Aether.installationMethod") private var installationMethod = 0
	@State private var isSpoofingPresented = false
	@AppStorage("Aether.deviceControlsStyle") private var controlsStyle: DeviceControlsStyle = .standard
	@State private var searchText = ""
	@State private var searchFocused = false
	@State private var rootVisible = false
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
			NBSettingsForm {
				if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
					settingsSections
				} else if !searchResults.isEmpty {
					Section {
						ForEach(searchResults) { entry in
							Button { openSearchResult(entry) } label: {
								HStack {
									NBTitleWithSubtitleView(title: entry.title, subtitle: entry.category)
									Image(systemName: entry.destination == .sourceCode ? "arrow.up.right" : "chevron.right")
										.font(.footnote.weight(.semibold)).foregroundStyle(Color.secondary)
								}
								.contentShape(Rectangle())
							}
							.buttonStyle(.plain)
							.disabled(!canOpenSearchResult(entry))
						}
					}
				}
			}
			.contentMargins(.top, 0, for: .scrollContent)
			.navigationBarTitleDisplayMode(.inline)
			.aetherAmbientScrollBackground(base: .grouped)
			.navigationDestination(for: AppTabManager.SettingsPage.self) { page in
				Group {
					switch page {
					case .appearance: AppearanceView()
					case .appIcon: AppIconView(currentIcon: $_currentIcon)
					case .certificates: CertificatesView()
					case .signing: ConfigurationView()
					case .archive: ArchiveView()
					case .installation: InstallationView()
					case .pairingFile: PairingFileView()
					case .tunnel: TunnelView()
					case .logs: LogsView()
					case .reset: ResetView()
					case .root, .spoofing: EmptyView()
					}
				}
			}
			.modifier(SearchToolbarModifier(
				text: $searchText, isPresented: $_tabManager.isSettingsSearchPresented,
				focus: $searchFocused, title: .localized("Settings"),
				isScreenActive: rootVisible && _settingsPath.isEmpty && !isSpoofingPresented,
				isTabRoot: true, hasTitleMenu: false
			) { EmptyView() })
			.overlay {
				if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && searchResults.isEmpty {
					TabPlaceholderView(title: .localized("No Results"), description: .localized("Try another search."), systemImage: "magnifyingglass")
				}
			}
			.onChange(of: _tabManager.isSettingsSearchPresented) { _, presented in
				if !presented { searchFocused = false }
				else { searchFocused = true }
			}
			.onDisappear { rootVisible = false; searchFocused = false }
			.onAppear {
				rootVisible = true
				_presentRequestedPageIfNeeded()
			}
			.onChange(of: _settingsPath) { _, path in
				if !path.isEmpty { searchFocused = false }
			}
			.onChange(of: _tabManager.requestedSettingsPage) { _, _ in
				_presentRequestedPageIfNeeded()
			}
		}
		.environment(\.nbGlassSettingsCards, controlsStyle == .liquidGlass)
		.modifier(FloatingNavigationAppearance())
		.sheet(isPresented: $isSpoofingPresented) { SpoofingEntryView() }
	}

	private var searchResults: [SettingsSearchEntry] { SettingsSearchIndex.results(for: searchText) }

	private var canOpenSpoofing: Bool {
		installationMethod == 1 && connection.isConnected && !connection.isUpdating
	}

	private func canOpenSearchResult(_ entry: SettingsSearchEntry) -> Bool {
		switch entry.destination {
		case .page(.tunnel), .page(.pairingFile): installationMethod == 1
		case .page(.spoofing): canOpenSpoofing
		default: true
		}
	}

	private func openSearchResult(_ entry: SettingsSearchEntry) {
		guard canOpenSearchResult(entry) else { return }
		searchFocused = false
		switch entry.destination {
		case .page(.spoofing):
			if canOpenSpoofing { isSpoofingPresented = true }
		case .page(let page): _settingsPath.append(page)
		case .sourceCode:
			if let url = URL(string: "https://github.com/a-artho/Aether") { UIApplication.shared.open(url) }
		}
	}

	private var deviceControls: some View {
		SettingsDeviceControls(
			certificate: selectedCertificate,
			openTunnel: { _settingsPath.append(connection.hasPairingFile ? .tunnel : .pairingFile) },
			openPairing: { _settingsPath.append(.pairingFile) },
			openSpoofing: { isSpoofingPresented = true },
			openCertificates: { _settingsPath.append(.certificates) }
		)
	}

	private var deviceControlsCard: some View {
		VStack(spacing: 12) {
			InstallationModePickerRow()
			deviceControls
		}
		.padding(12)
	}

	private var deviceControlsBackground: Color {
		Color(uiColor: UIColor { traits in
			traits.userInterfaceStyle == .dark
				? UIColor(white: 0.07, alpha: 1)
				: UIColor(white: 0.98, alpha: 1)
		})
	}

	@ViewBuilder private var settingsSections: some View {
		Section {
			if controlsStyle == .liquidGlass {
				deviceControlsCard
					.containerValue(\.nbSettingsCardOwnPadding, true)
					.listRowInsets(EdgeInsets())
					.listRowBackground(Color.clear)
					.listRowSeparator(.hidden)
			} else {
				InstallationModePickerRow()
					.listRowBackground(deviceControlsBackground)
				deviceControls
					.listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
					.listRowBackground(deviceControlsBackground)
			}
		}
		Section {
			NavigationLink(value: AppTabManager.SettingsPage.signing) {
				SettingsRowLabel(.localized("Signing Options"), systemImage: "signature", backgroundColor: .orange)
			}
			NavigationLink(value: AppTabManager.SettingsPage.archive) {
				SettingsRowLabel(.localized("Archive & Compression"), systemImage: "archivebox.fill", backgroundColor: .cyan)
			}
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

	private func _presentRequestedPageIfNeeded() {
		guard _tabManager.selectedTab == .settings, let page = _tabManager.requestedSettingsPage else { return }
		_settingsPath = page == .root || page == .spoofing ? [] : [page]
		if page == .spoofing { isSpoofingPresented = true }
		if page == .root && _tabManager.isSettingsSearchPresented { searchFocused = true }
		_tabManager.requestedSettingsPage = nil
	}
}
