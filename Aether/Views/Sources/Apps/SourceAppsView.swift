//
//  SourceAppsView.swift
//  Aether
//
//  Created by samara on 1.05.2025.
//

import SwiftUI
import AltSourceKit
import NimbleViews
import UIKit

// MARK: - Extension: View (Enil)
extension SourceAppsView {
	enum SortOption: String, CaseIterable {
		case `default` = "default"
		case name
		case date
		
		var displayName: String {
			switch self {
			case .default:  .localized("Default")
			case .name: 	.localized("Name")
			case .date: 	.localized("Date")
			}
		}
	}
}

// MARK: - View
struct SourceAppsView: View {
	@AppStorage("Aether.sortOptionRawValue") private var _sortOptionRawValue: String = SortOption.default.rawValue
	@AppStorage("Aether.sortAscending") private var _sortAscending: Bool = true
	
	@State private var _sortOption: SortOption = .default
	@State private var _selectedRoute: SourceAppRoute?
	
	@State var isLoading = true
	@State var hasLoadedOnce = false
	@State private var _searchText = ""
	@State private var _isSearchPresented = false
	@FocusState private var _isSearchFocused: Bool

	private var _navigationTitle: String {
		if object.count == 1 {
			object[0].name ?? .localized("Unknown")
		} else {
			.localized("%lld Sources", arguments: object.count)
		}
	}
	
	var object: [AltSource]
	@ObservedObject var viewModel: SourcesViewModel
	var isAllRepos: Bool = false
	@State private var _sourceContexts: [SourceRepositoryContext]?
	
	// MARK: Body
	var body: some View {
		ZStack {
			if
				let _sourceContexts,
				!_sourceContexts.isEmpty
			{
				SourceAppsTableRepresentableView(
					sourceContexts: _sourceContexts,
					searchText: $_searchText,
					sortOption: $_sortOption,
					sortAscending: $_sortAscending,
					showSourceBadge: isAllRepos,
					onSelect: {self._selectedRoute = $0}
				)
				.ignoresSafeArea()
			} else if isLoading {
				ProgressView()
			} else {
				TabPlaceholderView(
					title: .localized("No Apps"),
					description: .localized("This repo does not contain any available apps."),
					systemImage: "square.dashed"
				)
			}
		}
		.navigationTitle(_isSearchPresented ? "" : _navigationTitle)
		.navigationBarBackButtonHidden(_isSearchPresented)
		.toolbarTitleMenuIf(!_isSearchPresented) {
			_sortActions()

			if
				let _sourceContexts,
				_sourceContexts.count == 1
			{
				Section {
					if let url = _sourceContexts[0].repository.website {
						Button(.localized("Visit Website"), systemImage: "globe") {
							UIApplication.open(url)
						}
					}

					if let url = _sourceContexts[0].repository.patreonURL {
						Button(.localized("Visit Patreon"), systemImage: "dollarsign.circle") {
							UIApplication.open(url)
						}
					}

					Button(.localized("Copy"), systemImage: "doc.on.doc") {
						guard !object.isEmpty else {
							UIAlertController.showAlertWithOk(
								title: .localized("Error"),
								message: .localized("No sources to copy")
							)
							return
						}
						UIPasteboard.general.string = object.compactMap {
							$0.sourceURL?.absoluteString
						}.joined(separator: "\n")
						UIAlertController.showAlertWithOk(
							title: .localized("Success"),
							message: .localized("Sources copied to clipboard")
						)
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
								// A toolbar principal item is created after the navigation
								// bar's layout pass. Focus from the field itself instead of
								// racing that layout with a fixed delay.
								DispatchQueue.main.async {
									guard _isSearchPresented else { return }
									_isSearchFocused = true
								}
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
						Color.clear
							.glassEffect(.regular, in: .capsule)
					}
				}

				ToolbarItem(placement: .topBarTrailing) {
					Button {
						_isSearchFocused = false
						_isSearchPresented = false
						_searchText = ""
					} label: {
						Image(systemName: "xmark")
					}
					.accessibilityLabel(.localized("Cancel"))
				}
			} else {
				ToolbarItem(placement: .topBarTrailing) {
					Button {
						_presentSearch()
					} label: {
						Image(systemName: "magnifyingglass")
					}
					.accessibilityLabel(.localized("Search"))
				}
			}
		}
		.onAppear {
			if !hasLoadedOnce, viewModel.isFinished {
				_load()
				hasLoadedOnce = true
			}
			_sortOption = SortOption(rawValue: _sortOptionRawValue) ?? .default
		}
		.onChange(of: viewModel.isFinished) { _ in
			_load()
		}
		.onChange(of: _sortOption) { newValue in
			_sortOptionRawValue = newValue.rawValue
		}
		.navigationDestinationIfAvailable(item: $_selectedRoute) { route in
			SourceAppsDetailView(
				sourceURL: route.sourceURL,
				source: route.source,
				app: route.app
			)
		}
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Aether.openSearch"))) { _ in
			_presentSearch()
		}
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Aether.closeSearch"))) { _ in
			_isSearchFocused = false
			_isSearchPresented = false
			_searchText = ""
		}
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Aether.openApp"))) { notif in
			let targetName = notif.userInfo?["name"] as? String
			if let context = _sourceContexts?.first(where: { ctx in
				ctx.repository.apps.contains(where: { app in
					targetName == nil || app.currentName.localizedCaseInsensitiveContains(targetName!)
				})
			}) ?? _sourceContexts?.first,
			let app = context.repository.apps.first(where: { app in
				targetName == nil || app.currentName.localizedCaseInsensitiveContains(targetName!)
			}) ?? context.repository.apps.first {
				_selectedRoute = SourceAppRoute(sourceURL: context.sourceURL, source: context.repository, app: app)
			}
		}
	}
	
	private func _load() {
		isLoading = true

		let loadedSources = object.compactMap { source -> SourceRepositoryContext? in
			guard let repository = viewModel.repository(for: source) else { return nil }
			return SourceRepositoryContext(sourceURL: source.sourceURL, repository: repository)
		}
		_sourceContexts = loadedSources
		withAnimation(.easeIn(duration: 0.2)) {
			isLoading = false
		}
	}

	private func _presentSearch() {
		guard !_isSearchPresented else { return }
		_isSearchPresented = true
	}
	
	struct SourceRepositoryContext: Equatable {
		let sourceURL: URL?
		let repository: ASRepository
		private let appFingerprint: String

		init(sourceURL: URL?, repository: ASRepository) {
			self.sourceURL = sourceURL
			self.repository = repository
			var fingerprint = ""
			for app in repository.apps {
				let identifier = app.currentUniqueId
				let version = app.currentVersion ?? ""
				fingerprint += "\(identifier.utf8.count):\(identifier)\u{1e}\(version.utf8.count):\(version)\u{1f}"
			}
			self.appFingerprint = fingerprint
		}
		
		static func == (lhs: SourceRepositoryContext, rhs: SourceRepositoryContext) -> Bool {
			lhs.sourceURL == rhs.sourceURL &&
			lhs.repository.id == rhs.repository.id &&
			lhs.repository.name == rhs.repository.name &&
			lhs.appFingerprint == rhs.appFingerprint
		}
	}
	
	struct SourceAppRoute: Identifiable, Hashable {
		let sourceURL: URL?
		let source: ASRepository
		let app: ASRepository.App
		let id: String = UUID().uuidString
	}
}

// MARK: - Extension: View (Sort)
extension SourceAppsView {
	@ViewBuilder
	private func _sortActions() -> some View {
		Section(.localized("Filter by")) {
			ForEach(SortOption.allCases, id: \.displayName) { opt in
				_sortButton(for: opt)
			}
		}
	}
	
	private func _sortButton(for option: SortOption) -> some View {
		Button {
			if _sortOption == option {
				_sortAscending.toggle()
			} else {
				_sortOption = option
				_sortAscending = true
			}
		} label: {
			HStack {
				Text(option.displayName)
				Spacer()
				if _sortOption == option {
					Image(systemName: _sortAscending ? "chevron.up" : "chevron.down")
				}
			}
		}
	}
}

import SwiftUI

extension View {
	@ViewBuilder
	func navigationDestinationIfAvailable<Item: Identifiable & Hashable, Destination: View>(
		item: Binding<Item?>,
		@ViewBuilder destination: @escaping (Item) -> Destination
	) -> some View {
		self.navigationDestination(item: item, destination: destination)
	}

	@ViewBuilder
	func toolbarTitleMenuIf<Content: View>(
		_ condition: Bool,
		@ViewBuilder content: () -> Content
	) -> some View {
		if condition {
			self.toolbarTitleMenu(content: content)
		} else {
			self
		}
	}
}
