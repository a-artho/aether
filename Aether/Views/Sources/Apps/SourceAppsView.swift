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
	@State var isLoading = true
	@State var hasLoadedOnce = false
	@State private var _searchText = ""
	@ObservedObject private var router = SourcesRouter.shared

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
	let collectionRoute: SourcesRouter.CollectionRoute
	@State private var _sourceContexts: [SourceRepositoryContext]?

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
					onSelect: { selection in
						router.openResolvedApp(
							parent: collectionRoute,
							sourceObjectURI: selection.sourceObjectURI,
							appUniqueID: selection.appUniqueID
						)
					}
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
		.navigationTitle(_navigationTitle)
		.toolbarTitleMenu {
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
			// Other toolbar items if any, search is provided natively by .searchable
		}
		.searchable(
			text: $_searchText,
			isPresented: _collectionSearchPresented,
			placement: .toolbar,
			prompt: Text(.localized("Search"))
		)
		.searchToolbarBehavior(.minimize)
		.onChange(of: router.searchTarget) { target in
			if target != .collection(collectionRoute) {
				_searchText = ""
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
		.onChange(of: router.pendingAppRequest) { _ in
			_consumePendingAppRequestIfPossible()
		}
	}
	
	private func _load() {
		isLoading = true

		let loadedSources = object.compactMap { source -> SourceRepositoryContext? in
			guard let repository = viewModel.repository(for: source) else { return nil }
			return SourceRepositoryContext(
				sourceObjectURI: source.objectID.uriRepresentation().absoluteString,
				sourceURL: source.sourceURL,
				repository: repository
			)
		}
		_sourceContexts = loadedSources
		withAnimation(.easeIn(duration: 0.2)) {
			isLoading = false
		}
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
			appUniqueID: app.currentUniqueId
		)
	}
	
	struct SourceRepositoryContext: Equatable {
		let sourceObjectURI: String
		let sourceURL: URL?
		let repository: ASRepository
		private let appFingerprint: String

		init(sourceObjectURI: String, sourceURL: URL?, repository: ASRepository) {
			self.sourceObjectURI = sourceObjectURI
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
			lhs.sourceObjectURI == rhs.sourceObjectURI &&
			lhs.sourceURL == rhs.sourceURL &&
			lhs.repository.id == rhs.repository.id &&
			lhs.repository.name == rhs.repository.name &&
			lhs.appFingerprint == rhs.appFingerprint
		}
	}
	
	struct SourceAppSelection: Hashable {
		let sourceObjectURI: String
		let appUniqueID: String
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
