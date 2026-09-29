//
//  SourcesView.swift
//  Feather
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
	@FocusState private var _isSearchFocused: Bool
	
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
		NBNavigationView(_isSearchPresented ? "" : .localized("Sources"), displayMode: .inline) {
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
				if _filteredSources.isEmpty {
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
				}
			}
			.toolbar {
				if _isSearchPresented {
					ToolbarItem(placement: .principal) {
						HStack(spacing: 8) {
							Image(systemName: "magnifyingglass")
								.font(.system(size: 15, weight: .semibold))
								.foregroundColor(.secondary)
								.padding(.leading, 12)
							
							TextField(.localized("Search"), text: $_searchText)
								.font(.system(size: 16))
								.focused($_isSearchFocused)
								.textInputAutocapitalization(.never)
								.disableAutocorrection(true)
								.onAppear {
									_isSearchFocused = true
								}
							
							if !_searchText.isEmpty {
								Button {
									_searchText = ""
								} label: {
									Image(systemName: "xmark.circle.fill")
										.font(.system(size: 14))
										.foregroundColor(.secondary)
								}
								.buttonStyle(.plain)
								.padding(.trailing, 8)
							}
						}
						.frame(height: 36)
						.frame(width: min(500, UIScreen.main.bounds.width - 74))
						.background {
							if #available(iOS 26.0, *) {
								Color.clear
									.glassEffect(.regular, in: .capsule)
							} else {
								Color(UIColor.secondarySystemFill)
							}
						}
					}
					
					ToolbarItem(placement: .topBarTrailing) {
						Button {
							_isSearchFocused = false
							withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
								_isSearchPresented = false
								_searchText = ""
							}
						} label: {
							Image(systemName: "xmark")
						}
						.accessibilityLabel(.localized("Cancel"))
					}
				} else {
					ToolbarItem(placement: .topBarLeading) {
						Button {
							withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
								_isSearchPresented = true
							}
						} label: {
							Image(systemName: "magnifyingglass")
						}
						.accessibilityLabel(.localized("Search"))
					}
					
					ToolbarItem(placement: .topBarTrailing) {
						Button {
							_isAddingPresenting = true
						} label: {
							Image(systemName: "plus")
						}
						.disabled(_addingSourceLoading)
						.accessibilityLabel(.localized("Add Source"))
					}
				}
			}
			.refreshable {
				await viewModel.fetchSources(_sources, refresh: true)
			}
			.sheet(isPresented: $_isAddingPresenting, onDismiss: { _initialAddSourceURL = "" }) {
				SourcesAddView(initialURL: _initialAddSourceURL)
					.id(_initialAddSourceURL)
			}
			.animation(.spring(response: 0.35, dampingFraction: 0.82), value: _isSearchPresented)
			.animation(.snappy(duration: 0.25), value: _searchText)
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Feather.openSearch"))) { _ in
				withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
					_isSearchPresented = true
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Feather.openAddSource"))) { notification in
				_initialAddSourceURL = notification.userInfo?["url"] as? String ?? ""
				_isAddingPresenting = true
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Feather.closeSearch"))) { _ in
				_isSearchFocused = false
				withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
					_isSearchPresented = false
					_searchText = ""
				}
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
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Feather.openAllRepos"))) { _ in
				_openAllReposNav = true
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Feather.openFirstSource"))) { _ in
				if let first = _sources.first {
					_selectedSourceForNav = first
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Feather.openSource"))) { notif in
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
