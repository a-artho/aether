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
	@AppStorage("Aether.simplifiedMode") private var simplifiedMode = false
	@AppStorage("Aether.installationMethod") private var installationMethod = 0
	@AppStorage("Aether.serverMethod") private var serverMethod = 1
	@AppStorage("Aether.userTintColor") private var themeTint = "#848ef9"
	@Environment(\.colorScheme) private var colorScheme
	@Environment(\.displayScale) private var displayScale
	
	@ObservedObject private var tabManager = AppTabManager.shared
	@ObservedObject private var connection = DeviceConnectionManager.shared
	
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
			ForEach(TabEnum.defaultTabs.filter { !simplifiedMode || $0 != .library }, id: \.hashValue) { tab in
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
		.onChange(of: simplifiedMode) { _, enabled in
			if enabled && tabManager.selectedTab == .library { tabManager.selectedTab = .installed }
		}
		.sheet(isPresented: $tabManager.isSettingsPresented) {
			SettingsView()
		}
	}

	@ViewBuilder
	private func tabLabel(for tab: TabEnum) -> some View {
		let icon = simplifiedMode && tab == .installed ? TabEnum.library.icon : tab.icon
		if hideTabBarLabels && horizontalSizeClass == .compact {
			label(for: tab, icon: icon)
				.labelStyle(.iconOnly)
		} else {
			label(for: tab, icon: icon)
		}
	}

	@ViewBuilder private func label(for tab: TabEnum, icon: String) -> some View {
		if tab == .installed {
			Label {
				Text(simplifiedMode ? TabEnum.library.title : tab.title)
			} icon: {
				Image(uiImage: DeviceTabStatusIcon.image(symbol: simplifiedMode ? icon + ".fill" : icon, ready: installationReady,
					selected: tabManager.selectedTab == .installed, tint: Color(hex: themeTint),
					colorScheme: colorScheme, scale: displayScale))
			}
		} else { Label(tab.title, systemImage: icon) }
	}

	private var installationReady: Bool {
		if installationMethod == 1 { return connection.isConnected }
		if serverMethod == 1 { return true }
		return ServerInstaller.getUrl("server", ext: "crt") != nil
			&& ServerInstaller.getUrl("server", ext: "pem") != nil
			&& ServerInstaller.getUrl("commonName", ext: "txt") != nil
	}

}
