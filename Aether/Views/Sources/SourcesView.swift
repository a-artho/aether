//
//  SourcesView.swift
//  Aether
//
//  Created by samara on 10.04.2025.
//

import CoreData
import AltSourceKit
import SwiftUI
import NimbleViews

// MARK: - View
struct SourcesView: View {
	@Environment(\.horizontalSizeClass) private var horizontalSizeClass
	@StateObject var viewModel = SourcesViewModel.shared
	@State private var _isAddingPresenting = false
	@State private var _addingSourceLoading = false
	@State private var _initialAddSourceURL = ""
	@State private var _searchText = ""
	@State private var _isSearchPresented = false
	@State private var _selectedSourceForNav: AltSource? = nil
	@State private var _openAllReposNav = false
	@ObservedObject private var tabManager = AppTabManager.shared
	
	private var _filteredSources: [AltSource] {
		_sources.filter { _searchText.isEmpty || ($0.name?.localizedCaseInsensitiveContains(_searchText) ?? false) }
	}
	
	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)],
		animation: .snappy
	) private var _sources: FetchedResults<AltSource>
	
	// MARK: Body
	var body: some View {
		NBNavigationView(.localized("Sources"), displayMode: .inline) {
			NBListAdaptable {
				if !_filteredSources.isEmpty {
					Section {
						NavigationLink {
							SourceAppsView(object: Array(_sources), viewModel: viewModel, isAllRepos: true)
						} label: {
							let isRegular = horizontalSizeClass != .compact
							HStack(spacing: 18) {
								Image("Repositories").appIconStyle()
								NBTitleWithSubtitleView(
									title: .localized("All Repos"),
									subtitle: .localized("See all apps from your sources")
								)
							}
							.padding(isRegular ? 12 : 0)
							.background(
								isRegular
									? RoundedRectangle(cornerRadius: 18, style: .continuous)
									.fill(Color(.quaternarySystemFill))
									: nil
							)
						}
						.buttonStyle(.plain)
						.listRowSeparator(.hidden)
					}
					
					NBSection(.localized("Repos")) {
						ForEach(_filteredSources) { source in
							NavigationLink {
								SourceAppsView(object: [source], viewModel: viewModel, isAllRepos: false)
							} label: {
								SourcesCellView(source: source)
							}
							.buttonStyle(.plain)
						}
					}
				}
			}
			.scrollDismissesKeyboard(.interactively)
			.overlay {
				if _sources.isEmpty {
					TabPlaceholderView(
						title: .localized("No Repos"),
						description: .localized("Get started by adding your first repo."),
						systemImage: "globe.desk.fill"
					) {
						Button {
							_isAddingPresenting = true
						} label: {
							NBButton(.localized("Add Source"), style: .text)
						}
						.buttonStyle(.borderless)
					}
					.transition(.opacity.animation(.easeInOut(duration: 0.2)))
				} else if !_searchText.isEmpty && _filteredSources.isEmpty {
					TabPlaceholderView(
						title: .localized("No Results"),
						description: .localized("Try another search."),
						systemImage: "magnifyingglass"
					)
					.transition(.opacity.animation(.easeInOut(duration: 0.2)))
				}
			}
			.toolbar {
				ToolbarItem(placement: .topBarLeading) {
					Button {
						_isAddingPresenting = true
					} label: {
						Image(systemName: "plus")
					}
					.disabled(_addingSourceLoading)
					.accessibilityLabel(.localized("Add Source"))
				}
			}
			.searchable(
				text: $_searchText,
				isPresented: $_isSearchPresented,
				placement: .toolbar,
				prompt: Text(.localized("Search"))
			)
			.searchToolbarBehavior(.minimize)
			.onChange(of: _isSearchPresented) { presented in
				if !presented {
					_searchText = ""
				}
			}
			.onChange(of: tabManager.isSourcesSearchRequested) { requested in
				if requested {
					_isSearchPresented = true
					tabManager.isSourcesSearchRequested = false
				}
			}
			.refreshable {
				await viewModel.fetchSources(_sources, refresh: true)
			}
			.sheet(isPresented: $_isAddingPresenting, onDismiss: { _initialAddSourceURL = "" }) {
				SourcesAddView(initialURL: _initialAddSourceURL)
					.id(_initialAddSourceURL)
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Aether.openAddSource"))) { notification in
				_initialAddSourceURL = notification.userInfo?["url"] as? String ?? ""
				_isAddingPresenting = true
			}
			.navigationDestination(isPresented: Binding(
				get: { _selectedSourceForNav != nil },
				set: { if !$0 { _selectedSourceForNav = nil } }
			)) {
				if let source = _selectedSourceForNav {
					SourceAppsView(object: [source], viewModel: viewModel, isAllRepos: false)
				}
			}
			.navigationDestination(isPresented: $_openAllReposNav) {
				SourceAppsView(object: Array(_sources), viewModel: viewModel, isAllRepos: true)
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Aether.openAllRepos"))) { _ in
				_openAllReposNav = true
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Aether.openFirstSource"))) { _ in
				if let first = _sources.first {
					_selectedSourceForNav = first
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Aether.openSource"))) { notif in
				if let name = notif.userInfo?["name"] as? String {
					if let found = _sources.first(where: { $0.name?.localizedCaseInsensitiveContains(name) == true }) {
						_selectedSourceForNav = found
					}
				} else if let first = _sources.first {
					_selectedSourceForNav = first
				}
			}
		}
		.task(id: Array(_sources)) {
			await viewModel.fetchSources(_sources)
		}
	}
}
