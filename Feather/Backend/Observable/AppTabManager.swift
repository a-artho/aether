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
	
	@Published var selectedTab: TabEnum = .sources
	
	private init() {}
	
	func switchTo(_ tab: TabEnum) {
		withAnimation(.easeInOut(duration: 0.25)) {
			self.selectedTab = tab
		}
	}
}
