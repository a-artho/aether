//
//  AppTabManager.swift
//  Feather
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
		case reset
	}
	
	@Published var selectedTab: TabEnum = .sources
	@Published var isSettingsPresented = false
	@Published var requestedSettingsPage: SettingsPage? = nil
	@Published private(set) var isInstallationSettingsRequested = false
	
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
		if selectedTab != .installed {
			withAnimation(.easeInOut(duration: 0.25)) {
				self.selectedTab = .installed
			}
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
				self.isSettingsPresented = true
			}
		} else {
			isSettingsPresented = true
		}
	}

	func openInstallationSettings() {
		openSettings(page: .installation)
	}

	func consumeInstallationSettingsRequest() {
		isInstallationSettingsRequested = false
	}
}
