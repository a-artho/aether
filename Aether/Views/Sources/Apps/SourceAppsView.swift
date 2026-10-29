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
		case `default`
		case name
		case latest

		var displayName: String {
			switch self {
			case .default: .localized("Default")
			case .name: 	.localized("Name")
			case .latest: 	.localized("Latest")
			}
		}
	}
}

// MARK: - View
struct SourceAppsView: View {
	@AppStorage("Aether.sortOptionRawValue") private var _sortOptionRawValue: String = SortOption.latest.rawValue

	@State private var _sortOption: SortOption = {
		let raw = UserDefaults.standard.string(forKey: "Aether.sortOptionRawValue") ?? "latest"
		return raw == "date" ? .latest : SortOption(rawValue: raw) ?? .latest
	}()
	@State private var _completedLoadKey: String?
	@State private var _loadAttempt = 0
	@State private var _searchText = ""
	@ObservedObject private var router = SourcesRouter.shared

	private var _isSearchPresented: Bool {
		router.searchTarget == .collection(collectionRoute)
	}

	private var _navigationTitle: String {
		if object.count == 1 {
			(object[0].name ?? .localized("Unknown")).repoDisplayName
		} else {
			.localized("%lld Sources", arguments: object.count)
		}
	}

	var object: [AltSource]
	@ObservedObject var viewModel: SourcesViewModel
	var isAllRepos: Bool = false
	let collectionRoute: SourcesRouter.CollectionRoute
	var searchFocus: Binding<Bool>
	@State private var _sourceContexts: [SourceRepositoryContext]?
	@State private var _loadedCatalogRevision: Int?
	@State private var _loadedSourceKeys: [String] = []

	private var _sourceKeys: [String] { object.map { $0.objectID.uriRepresentation().absoluteString } }
	private var _loadKey: String { "\(_sourceKeys)|\(viewModel.cacheGeneration)|\(_loadAttempt)" }
	private var isLoading: Bool {
		(_sourceContexts?.contains { !$0.repository.apps.isEmpty } != true) && _completedLoadKey != _loadKey
	}
	private var _loadFailure: String? {
		guard _completedLoadKey == _loadKey,
			object.contains(where: { viewModel.repository(for: $0) == nil }) else { return nil }
		return object.compactMap { viewModel.refreshErrors[$0.objectID.uriRepresentation().absoluteString] }.first
			?? .localized("Unable to load this repo. Try again.")
	}

	private var _collectionSearchPresented: Binding<Bool> {
		Binding(
			get: { router.searchTarget == .collection(collectionRoute) },
			set: { presented in
				let target = SourcesRouter.SearchTarget.collection(collectionRoute)
				if presented {
					router.searchTarget = target
				} else if router.searchTarget == target {
					router.searchTarget = nil
				}
			}
		)
	}

	// MARK: Body
	var body: some View {
		ZStack {
			AetherAmbientBackground()

			if isLoading || (_sourceContexts?.contains(where: { !$0.repository.apps.isEmpty }) == true) {
				SourceAppsTableRepresentableView(
					sourceContexts: _sourceContexts ?? [],
					isCatalogLoading: isLoading,
					isSearchPresented: _isSearchPresented,
					searchText: $_searchText,
					sortOption: $_sortOption,
					sortAscending: _sortOption == .name,
					showSourceBadge: isAllRepos,
					onSelect: { selection in
						searchFocus.wrappedValue = false
						router.openResolvedApp(
							parent: collectionRoute,
							sourceObjectURI: selection.sourceObjectURI,
							appLocator: selection.appLocator
						)
					}
				)
				.ignoresSafeArea()
			} else if let error = _loadFailure {
				TabPlaceholderView(title: .localized("Unable to Load Repo"), description: error,
					systemImage: "exclamationmark.triangle") {
					Button { _loadAttempt += 1 } label: { Text(.localized("Retry")) }
				}
			} else {
				TabPlaceholderView(
					title: .localized("No Apps"),
					description: .localized("This repo does not contain any available apps."),
					systemImage: "square.dashed"
				)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.modifier(SearchToolbarModifier(
			text: $_searchText, isPresented: _collectionSearchPresented,
			focus: searchFocus, title: _navigationTitle,
			isScreenActive: router.path.last == .collection(collectionRoute),
			hasTitleSearchMenu: true,
			secondarySymbol: "line.3.horizontal.decrease", secondaryLabel: .localized("Filter")
		) { _repoMenuActions() })

		.onChange(of: router.searchTarget) { _, target in
			if target != .collection(collectionRoute) {
				searchFocus.wrappedValue = false
				if target != nil { _searchText = "" }
			}
		}
		.onAppear {
			_load()
			_sortOption = _sortOptionRawValue == "date"
				? .latest
				: SortOption(rawValue: _sortOptionRawValue) ?? .latest
		}
		.task(id: _loadKey) {
			let key = _loadKey
			await viewModel.ensureSourcesLoaded(object)
			guard !Task.isCancelled, key == _loadKey else { return }
			_load()
			_completedLoadKey = key
		}
		.onChange(of: viewModel.catalogRevision) { _, _ in
			_load()
		}
		.onChange(of: _sortOption) { _, newValue in
			_sortOptionRawValue = newValue.rawValue
		}
		.onChange(of: router.pendingAppRequest) { _, _ in
			_consumePendingAppRequestIfPossible()
		}
	}

	@ViewBuilder
	private func _repoMenuActions() -> some View {
		_sortActions()
		if let contexts = _sourceContexts, contexts.count == 1,
			let url = contexts[0].repository.patreonURL {
			Section {
				Button(.localized("Visit Patreon"), systemImage: "dollarsign.circle") { UIApplication.open(url) }
			}
		}
	}

	private func _load() {
		guard _loadedCatalogRevision != viewModel.catalogRevision || _loadedSourceKeys != _sourceKeys else {
			_consumePendingAppRequestIfPossible()
			return
		}
		let loadedSources = object.compactMap { source -> SourceRepositoryContext? in
			guard var repository = viewModel.repository(for: source) else { return nil }
			// The catalog screen renders app rows only; don't retain the manifest's news payload here.
			repository.news = nil
			return SourceRepositoryContext(
				sourceObjectURI: source.objectID.uriRepresentation().absoluteString,
				sourceURL: source.sourceURL,
				repository: repository,
				revision: viewModel.revision(for: source)
			)
		}
		if _sourceContexts != loadedSources { _sourceContexts = loadedSources }
		_loadedCatalogRevision = viewModel.catalogRevision
		_loadedSourceKeys = _sourceKeys
		_consumePendingAppRequestIfPossible()
	}

	private func _consumePendingAppRequestIfPossible() {
		guard
			let request = router.pendingAppRequest,
			request.parent == collectionRoute,
			let contexts = _sourceContexts,
			let context = contexts.first(where: { $0.sourceObjectURI == request.sourceObjectURI })
		else {
			return
		}

		let app: ASRepository.App?
		if let appName = request.appName {
			app = context.repository.apps.first {
				$0.currentName.localizedCaseInsensitiveContains(appName)
			}
		} else {
			app = context.repository.apps.first
		}

		guard let app else {
			router.pendingAppRequest = nil
			return
		}

		router.openResolvedApp(
			parent: request.parent,
			sourceObjectURI: request.sourceObjectURI,
			appLocator: .locator(for: app)
		)
	}

	typealias SourceRepositoryContext = SourceAppCatalogContext

	struct SourceAppSelection: Hashable {
		let sourceObjectURI: String
		let appLocator: SourcesRouter.AppLocator
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
			_sortOption = option
		} label: {
			HStack {
				Text(option.displayName)
				Spacer()
				if _sortOption == option {
					Image(systemName: "checkmark")
				}
			}
		}
	}
}
