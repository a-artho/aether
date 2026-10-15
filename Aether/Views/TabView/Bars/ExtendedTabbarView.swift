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
			ForEach(TabEnum.defaultTabs, id: \.self) { tab in
				Tab(value: tab.rawValue) {
					TabEnum.view(for: tab)
				} label: {
					tabLabel(for: tab)
				}
			}
			
			ForEach(TabEnum.customizableTabs, id: \.hashValue) { tab in
				Tab(value: tab.rawValue) {
					TabEnum.view(for: tab)
				} label: {
					tabLabel(for: tab)
				}
				.customizationID("tab.\(tab.rawValue)")
				.defaultVisibility(.hidden, for: .tabBar)
				.customizationBehavior(.reorderable, for: .tabBar, .sidebar)
				.hidden(horizontalSizeClass == .compact)
			}
			
		}
		.tabViewStyle(.sidebarAdaptable)
		.tabViewCustomization($customization)
	}

	@ViewBuilder
	private func tabLabel(for tab: TabEnum) -> some View {
		let icon = tab.icon
		if hideTabBarLabels && horizontalSizeClass == .compact {
			Label(tab.title, systemImage: tab == .library ? icon + ".fill" : icon)
				.labelStyle(.iconOnly)
		} else {
			Label(tab.title, systemImage: tab == .library ? icon + ".fill" : icon)
		}
	}

}
