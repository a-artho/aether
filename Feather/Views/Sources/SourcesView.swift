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
	@State private var _searchText = ""
	@State private var _isSearchPresented = false
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
							SourceAppsView(object: Array(_sources), viewModel: viewModel)
						} label: {
							let isRegular = horizontalSizeClass != .compact
							HStack(spacing: 18) {
								Image("Repositories").appIconStyle()
								NBTitleWithSubtitleView(
									title: .localized("All Repositories"),
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
					}
					
					NBSection(
						.localized("Repositories"),
						secondary: _filteredSources.count.description
					) {
						ForEach(_filteredSources) { source in
							NavigationLink {
								SourceAppsView(object: [source], viewModel: viewModel)
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
					if #available(iOS 17, *) {
						ContentUnavailableView {
							Label(.localized("No Repositories"), systemImage: "globe.desk.fill")
						} description: {
							Text(.localized("Get started by adding your first repository."))
						} actions: {
							Button {
								_isAddingPresenting = true
							} label: {
								NBButton(.localized("Add Source"), style: .text)
							}
						}
					}
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
						.background(Color(UIColor.secondarySystemFill), in: Capsule())
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
			.sheet(isPresented: $_isAddingPresenting) {
				SourcesAddView()
			}
			.animation(.spring(response: 0.35, dampingFraction: 0.82), value: _isSearchPresented)
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Feather.openSearch"))) { _ in
				withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
					_isSearchPresented = true
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Feather.closeSearch"))) { _ in
				_isSearchFocused = false
				withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
					_isSearchPresented = false
					_searchText = ""
				}
			}
		}
		.task(id: Array(_sources)) {
			await viewModel.fetchSources(_sources)
		}
	}
}
