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
		case installation
		case pairingFile = "pairing-file"
		case tunnel
		case spoofing
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
	@Published var requestedSettingsPage: SettingsPage? = nil
	@Published var isLibrarySearchPresented = false
	@Published var isSettingsSearchPresented = false
	@Published private(set) var installationFocusRequest: UUID?
	@Published private(set) var libraryFocusRequest: UUID?

	private init() {}

	func switchTo(_ tab: TabEnum, focusImports: Bool = true) {
		if tab == .settings {
			openSettings()
			return
		}
		if tab == .library && focusImports {
			libraryFocusRequest = UUID()
		}
		withAnimation(.easeInOut(duration: 0.25)) {
			self.selectedTab = tab
		}
	}

	func showInstallQueue() {
		libraryFocusRequest = nil
		installationFocusRequest = UUID()
		switchTo(.library, focusImports: false)
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
		requestedSettingsPage = page ?? .root
		selectedTab = .settings
	}

	func openInstallationSettings() {
		openSettings(page: .installation)
	}

	func openSearch() {
		switch selectedTab {
		case .settings:
			requestedSettingsPage = .root
			isSettingsSearchPresented = true
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
		isSettingsSearchPresented = false
		isLibrarySearchPresented = false
		SourcesRouter.shared.closeSearch()
	}
}
