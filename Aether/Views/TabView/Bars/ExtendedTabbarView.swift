//
//  TabbarController.swift
//  aether
//
//  Created by samara on 5/17/24.
//  Copyright (c) 2024 Samara M (khcrysalis)
//

import SwiftUI
import NukeUI

struct ExtendedTabbarView: View {
	@Environment(\.horizontalSizeClass) var horizontalSizeClass
	@AppStorage("Aether.tabCustomization") var customization = TabViewCustomization()
	@StateObject var viewModel = SourcesViewModel.shared
	
	@State private var _isAddingPresenting = false
	
	@ObservedObject private var tabManager = AppTabManager.shared
	
	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)],
		animation: .snappy
	) private var _sources: FetchedResults<AltSource>
	
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
				Tab(tab.title, systemImage: tab.icon, value: tab.rawValue) {
					TabEnum.view(for: tab)
				}
			}
			
			ForEach(TabEnum.customizableTabs, id: \.hashValue) { tab in
				Tab(tab.title, systemImage: tab.icon, value: tab.rawValue) {
					TabEnum.view(for: tab)
				}
				.customizationID("tab.\(tab.rawValue)")
				.defaultVisibility(.hidden, for: .tabBar)
				.customizationBehavior(.reorderable, for: .tabBar, .sidebar)
				.hidden(horizontalSizeClass == .compact)
			}
			
			TabSection("Sources") {
				Tab(.localized("All Repos"), systemImage: "globe.desk", value: "all_repositories") {
					NavigationStack {
						SourceAppsView(object: Array(_sources), viewModel: viewModel, isAllRepos: true)
					}
				}
				
				ForEach(_sources, id: \.identifier) { source in
					Tab(value: "source.\(source.identifier ?? UUID().uuidString)") {
						NavigationStack {
							SourceAppsView(object: [source], viewModel: viewModel, isAllRepos: false)
						}
					} label: {
						_icon(source.name ?? .localized("Unknown"), iconUrl: source.iconURL)
					}
					.swipeActions {
						Button(.localized("Delete"), systemImage: "trash", role: .destructive) {
							Storage.shared.deleteSource(for: source)
						}
					}
				}
			}
			.sectionActions {
				Button(.localized("Add Source"), systemImage: "plus") {
					_isAddingPresenting = true
				}
			}
			.defaultVisibility(.hidden, for: .tabBar)
			.hidden(horizontalSizeClass == .compact)
		}
		.tabViewStyle(.sidebarAdaptable)
		.tabViewCustomization($customization)
		.sheet(isPresented: $_isAddingPresenting) {
			SourcesAddView()
				.presentationDetents([.medium])
		}
	}
	
	@ViewBuilder
	private func _icon(_ title: String, iconUrl: URL?) -> some View {
		Label {
			Text(title)
		} icon: {
			if let iconURL = iconUrl {
				LazyImage(url: iconURL) { state in
					if let image = state.image {
						image
					} else {
						standardIcon
					}
				}
				.processors([.resize(width: 14), .circle()])
			} else {
				standardIcon
			}
		}
	}

	
	var standardIcon: some View {
		Image(systemName: "app.dashed")
	}
}
