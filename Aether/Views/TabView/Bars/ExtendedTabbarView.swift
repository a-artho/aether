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
	@AppStorage("Aether.settingsPlacement") private var settingsPlacement: SettingsPlacement = .header
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
		
	private var settingsTabEnabled: Bool { SettingsPlacement.usesTab(placement: settingsPlacement) }
	private var defaultTabs: [TabEnum] {
		let tabs = TabEnum.defaultTabs
		return settingsTabEnabled ? tabs + [.settings] : tabs
	}

	var body: some View {
		TabView(selection: _selectedTabBinding) {
			ForEach(defaultTabs, id: \.self) { tab in
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
		.onChange(of: settingsTabEnabled) { _, enabled in
			let page = tabManager.requestedSettingsPage ?? tabManager.visibleSettingsPage
			if enabled && tabManager.isSettingsPresented {
				tabManager.openSettings(page: page)
			} else if !enabled && tabManager.selectedTab == .settings {
				tabManager.selectedTab = .library
				tabManager.openSettings(page: page)
			}
		}
		.sheet(isPresented: $tabManager.isSettingsPresented) {
			SettingsView()
		}
	}

	@ViewBuilder
	private func tabLabel(for tab: TabEnum) -> some View {
		let icon = tab.icon
		if hideTabBarLabels && horizontalSizeClass == .compact {
			label(for: tab, icon: icon)
				.labelStyle(.iconOnly)
		} else {
			label(for: tab, icon: icon)
		}
	}

	@ViewBuilder private func label(for tab: TabEnum, icon: String) -> some View {
		if tab == .library {
			Label {
				Text(tab.title)
			} icon: {
				Image(uiImage: DeviceTabStatusIcon.image(symbol: icon + ".fill", ready: installationReady,
					selected: tabManager.selectedTab == .library, tint: Color(hex: themeTint),
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
