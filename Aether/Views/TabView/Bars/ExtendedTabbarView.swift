//
//  TabbarController.swift
//  aether
//
//  Created by samara on 5/17/24.
//  Copyright (c) 2024 Samara M (khcrysalis)
//

import SwiftUI
import UIKit
import NimbleExtensions

struct ExtendedTabbarView: View {
	@Environment(\.horizontalSizeClass) var horizontalSizeClass
	@Environment(\.colorScheme) private var colorScheme
	@AppStorage("Aether.spoofing.simulationMayBeActive") private var isSpoofingActive = false
	@AppStorage("Aether.userTintColor") private var tintHex = "#848ef9"
	@AppStorage("Aether.tabCustomization") var customization = TabViewCustomization()
	
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

	private func tabLabel(for tab: TabEnum) -> some View {
		Label {
			Text(tab.title)
		} icon: {
			if tab == .settings && isSpoofingActive {
				Image(uiImage: SpoofingTabIcon.image(selected: tabManager.selectedTab == .settings,
					tintHex: tintHex, dark: colorScheme == .dark))
					.renderingMode(.original)
			} else {
				Image(systemName: tab == .library ? tab.icon + ".fill" : tab.icon)
			}
		}
		.labelStyle(.iconOnly)
	}
}

/// A native tab item accepts one image; compose its small indicator into that
/// image rather than placing an overlay over the system tab bar.
@MainActor
private enum SpoofingTabIcon {
	private static let cache: NSCache<NSString, UIImage> = {
		let cache = NSCache<NSString, UIImage>()
		cache.countLimit = 8
		return cache
	}()

	static func image(selected: Bool, tintHex: String, dark: Bool) -> UIImage {
		let key = "\(selected)|\(tintHex)|\(dark)" as NSString
		if let image = cache.object(forKey: key) { return image }
		let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
		let foreground = selected ? UIColor(Color(hex: tintHex)) : UIColor.label.resolvedColor(with: traits)
		let image = UIGraphicsImageRenderer(size: CGSize(width: 28, height: 28)).image { context in
			UIImage(systemName: "gearshape", withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .regular))?
				.withTintColor(foreground, renderingMode: .alwaysOriginal)
				.draw(in: CGRect(x: 1, y: 3, width: 24, height: 24))
			let badge = CGRect(x: 18, y: 0, width: 10, height: 10)
			context.cgContext.setFillColor(UIColor.systemGreen.resolvedColor(with: traits).cgColor)
			context.cgContext.fillEllipse(in: badge)
			UIImage(systemName: "location.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 6, weight: .semibold))?
				.withTintColor(.white, renderingMode: .alwaysOriginal)
				.draw(in: badge.insetBy(dx: 2, dy: 2))
		}.withRenderingMode(.alwaysOriginal)
		cache.setObject(image, forKey: key)
		return image
	}
}
