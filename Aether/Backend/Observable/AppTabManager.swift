//
//  AppTabManager.swift
//  Aether
//
//  Created by samara on 28.09.2026.
//

import SwiftUI

@MainActor
final class AppTabManager: ObservableObject {
	static let shared = AppTabManager()

	enum SettingsPage: String {
		case appearance
		case appIcon = "app-icon"
		case certificates
		case signing
		case archive
		case serverConfig = "server-config"
		case installation
		case pairingFile = "pairing-file"
		case tunnel
		case logs
		case reset
		case root
	}

	@Published var selectedTab: TabEnum = .sources {
		didSet {
			guard selectedTab != oldValue else { return }
			var transaction = Transaction()
			transaction.disablesAnimations = true
			withTransaction(transaction) {
				closeSearch()
			}
		}
	}
	@Published var isSettingsPresented = false
	@Published var requestedSettingsPage: SettingsPage? = nil
	@Published var isLibrarySearchPresented = false
	@Published var isDeviceSearchPresented = false
	enum LibraryAction: Equatable { case select, deleteAll }
	@Published var requestedLibraryAction: LibraryAction?
	@Published private(set) var installationFocusRequest: UUID?
	@Published private(set) var libraryFocusRequest: UUID?

	private init() {}

	func switchTo(_ tab: TabEnum) {
		if tab == .settings {
			openSettings()
			return
		}
		isSettingsPresented = false
		if tab == .library && UserDefaults.standard.bool(forKey: "Aether.simplifiedMode") {
			libraryFocusRequest = UUID()
		}
		withAnimation(.easeInOut(duration: 0.25)) {
			self.selectedTab = tab == .library && UserDefaults.standard.bool(forKey: "Aether.simplifiedMode") ? .installed : tab
		}
	}

	func showInstallQueue() {
		installationFocusRequest = UUID()
		switchTo(.installed)
	}

	func consumeInstallationFocusRequest(_ request: UUID) {
		guard installationFocusRequest == request else { return }
		installationFocusRequest = nil
	}

	func consumeLibraryFocusRequest(_ request: UUID) {
		guard libraryFocusRequest == request else { return }
		libraryFocusRequest = nil
	}

	func openSettings(page: SettingsPage? = nil) {
		requestedSettingsPage = page
		isSettingsPresented = true
	}

	func openInstallationSettings() {
		openSettings(page: .installation)
	}

	func openSearch() {
		switch selectedTab {
		case .library:
			isLibrarySearchPresented = true
		case .installed:
			isDeviceSearchPresented = true
		case .sources:
			SourcesRouter.shared.openSearchForVisibleScreen()
		default:
			switchTo(.sources)
			SourcesRouter.shared.path = []
			SourcesRouter.shared.searchTarget = .root
		}
	}

	func closeSearch() {
		isLibrarySearchPresented = false
		isDeviceSearchPresented = false
		SourcesRouter.shared.closeSearch()
	}
}
