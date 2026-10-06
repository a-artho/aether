//
//  TabbarController.swift
//  aether
//
//  Created by samara on 5/17/24.
//  Copyright (c) 2024 Samara M (khcrysalis)
//

import SwiftUI

struct ExtendedTabbarView: View {
	@Environment(\.horizontalSizeClass) var horizontalSizeClass
	@AppStorage("Aether.tabCustomization") var customization = TabViewCustomization()
	@AppStorage("Aether.hideTabBarLabels") private var hideTabBarLabels = false
	
	@ObservedObject private var tabManager = AppTabManager.shared
	@ObservedObject private var installationManager = AppInstallationManager.shared
	
	private var _selectedTabBinding: Binding<String> {
		Binding(
			get: { tabManager.selectedTab.rawValue },
			set: { newValue in
				if let tab = TabEnum(rawValue: newValue) {
					tabManager.selectedTab = tab
				}
			}
		)
	}
		
	var body: some View {
		TabView(selection: _selectedTabBinding) {
			ForEach(TabEnum.defaultTabs, id: \.hashValue) { tab in
				Tab(value: tab.rawValue) {
					TabEnum.view(for: tab)
				} label: {
					tabLabel(for: tab)
				}
				.badge(tab == .installed ? installationManager.pendingInstallationCount : 0)
			}
			
			ForEach(TabEnum.customizableTabs, id: \.hashValue) { tab in
				Tab(value: tab.rawValue) {
					TabEnum.view(for: tab)
				} label: {
					tabLabel(for: tab)
				}
				.badge(tab == .installed ? installationManager.pendingInstallationCount : 0)
				.customizationID("tab.\(tab.rawValue)")
				.defaultVisibility(.hidden, for: .tabBar)
				.customizationBehavior(.reorderable, for: .tabBar, .sidebar)
				.hidden(horizontalSizeClass == .compact)
			}
			
		}
		.tabViewStyle(.sidebarAdaptable)
		.tabViewCustomization($customization)
		.sheet(isPresented: $tabManager.isSettingsPresented) {
			SettingsView()
		}
	}

	@ViewBuilder
	private func tabLabel(for tab: TabEnum) -> some View {
		if hideTabBarLabels && horizontalSizeClass == .compact {
			Label(tab.title, systemImage: tab.icon)
				.labelStyle(.iconOnly)
		} else {
			Label(tab.title, systemImage: tab.icon)
		}
	}

}
