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
	@Published private(set) var isInstallationSettingsRequested = false
	@Published var isLibrarySearchPresented = false
	
	private init() {}
	
	func switchTo(_ tab: TabEnum) {
		if tab == .settings {
			openSettings()
			return
		}
		isSettingsPresented = false
		withAnimation(.easeInOut(duration: 0.25)) {
			self.selectedTab = tab
		}
	}

	func openSettings(page: SettingsPage? = nil) {
		requestedSettingsPage = page
		isSettingsPresented = true
	}

	func openInstallationSettings() {
		openSettings(page: .installation)
	}

	func consumeInstallationSettingsRequest() {
		isInstallationSettingsRequested = false
	}

	func openSearch() {
		switch selectedTab {
		case .library:
			isLibrarySearchPresented = true
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
		SourcesRouter.shared.closeSearch()
	}
}
