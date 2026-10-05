//
//  SourcesView.swift
//  Aether
//

import CoreData
import AltSourceKit
import SwiftUI
import NimbleViews

struct SourcesView: View {
	@Environment(\.scenePhase) private var _scenePhase
	@StateObject var viewModel = SourcesViewModel.shared
	@State private var _searchText = ""
	@State private var _refreshErrorMessage: String?
	@State private var _toolbarWidth: CGFloat = 320
	@State private var _isSearchFocused = false
	// Keep the collection keyboard state outside the pushed destination.
	@State private var _isCollectionSearchFocused = false
	@ObservedObject private var router = SourcesRouter.shared

	private var _filteredSources: [AltSource] {
		_sources.filter {
			_searchText.isEmpty || ($0.name?.localizedCaseInsensitiveContains(_searchText) ?? false)
		}
	}

	private var _sourceIdentitySnapshot: [String] {
		_sources.map { $0.objectID.uriRepresentation().absoluteString }
	}

	private var _rootSearchPresented: Binding<Bool> {
		Binding(
			get: { router.searchTarget == .root },
			set: { presented in
				if presented {
					router.searchTarget = .root
				} else if router.searchTarget == .root {
					router.searchTarget = nil
				}
			}
		)
	}

	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)],
		animation: .snappy
	) private var _sources: FetchedResults<AltSource>

	var body: some View {
		NavigationStack(path: $router.path) {
			NBListAdaptable {
				if !_filteredSources.isEmpty {
					Section {
						NavigationLink(value: SourcesRouter.Route.collection(.allRepos)) {
							HStack(spacing: 18) {
								Image("Repositories").appIconStyle()
								NBTitleWithSubtitleView(
									title: .localized("All Repos"),
									subtitle: .localized("See all apps from your sources")
								)
							}
						}
						.buttonStyle(.plain)
						.listRowSeparator(.hidden)
					}

					NBSection(.localized("Repos"), trailing: {
						SourceRefreshStatusView(
							lastUpdated: viewModel.lastUpdated,
							isRefreshing: !viewModel.isFinished,
							hasFailures: !viewModel.refreshErrors.isEmpty
						)
					}) {
						ForEach(_filteredSources) { source in
							NavigationLink(
								value: SourcesRouter.Route.collection(
									.source(objectURI: source.objectID.uriRepresentation().absoluteString)
								)
							) {
								SourcesCellView(source: source)
							}
							.buttonStyle(.plain)
						}
					}
				}
			}
			.scrollDismissesKeyboard(.immediately)
			.overlay {
				if _sources.isEmpty {
					TabPlaceholderView(
						title: .localized("No Repos"),
						description: .localized("Get started by adding your first repo."),
						systemImage: "globe.desk.fill"
					) {
						Button {
							router.presentAddSource()
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
			.navigationBarTitleDisplayMode(.inline)
			.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { _toolbarWidth = $0 }
			.modifier(SearchToolbarModifier(
				text: $_searchText, isPresented: _rootSearchPresented,
				focus: $_isSearchFocused, title: .localized("Sources"), width: _toolbarWidth, hasTitleMenu: false,
				secondaryLabel: .localized("Add Source"),
				secondaryAction: { router.presentAddSource() }
			) { EmptyView() })
			.onChange(of: router.searchTarget) { target in
				switch target {
				case .some(.collection(_)):
					break
				default:
					_isCollectionSearchFocused = false
				}
				if target != .root {
					_isSearchFocused = false
					_searchText = ""
				}
			}
			.refreshable {
				await viewModel.fetchSources(_sources, refresh: true)
				let failures = _sources.compactMap { source -> String? in
					let key = source.objectID.uriRepresentation().absoluteString
					guard let error = viewModel.refreshErrors[key] else { return nil }
					return "\(source.name ?? source.sourceURL?.absoluteString ?? "Source"): \(error)"
				}
				_refreshErrorMessage = failures.isEmpty ? nil : failures.joined(separator: "\n\n")
			}
			.alert(.localized("Refresh Failed"), isPresented: Binding(
				get: { _refreshErrorMessage != nil },
				set: { if !$0 { _refreshErrorMessage = nil } }
			)) {
				Button(.localized("OK"), role: .cancel) { _refreshErrorMessage = nil }
			} message: {
				Text(_refreshErrorMessage ?? "")
			}
			.navigationDestination(for: SourcesRouter.Route.self) { route in
				switch route {
				case .collection(.allRepos):
					SourceAppsView(
						object: Array(_sources),
						viewModel: viewModel,
						isAllRepos: true,
						collectionRoute: .allRepos,
						searchFocus: $_isCollectionSearchFocused
					)
				case .collection(.source(let objectURI)):
					if let source = _source(withObjectURI: objectURI) {
						SourceAppsView(
							object: [source],
							viewModel: viewModel,
							isAllRepos: false,
							collectionRoute: .source(objectURI: objectURI),
							searchFocus: $_isCollectionSearchFocused
						)
					} else {
						_unavailableSourceView()
					}
				case .app(_, let sourceObjectURI, let appLocator):
					_appDestination(sourceObjectURI: sourceObjectURI, appLocator: appLocator)
				}
			}
		}
		.sheet(item: $router.addSourceRequest) { request in
			SourcesAddView(initialURL: request.initialURL)
				.id(request.id)
		}
		.onAppear {
			_resolvePendingNavigationIntent()
		}
		.onChange(of: router.navigationIntent) { _ in
			_resolvePendingNavigationIntent()
		}
		.onChange(of: _sourceIdentitySnapshot) { _ in
			_resolvePendingNavigationIntent()
		}
		.task(id: _sourceIdentitySnapshot) {
			await viewModel.refreshIfNeeded(Array(_sources))
		}
		.task(id: _scenePhase) {
			if _scenePhase == .active {
				await viewModel.refreshIfNeeded(Array(_sources))
			}
		}
	}

	private func _source(withObjectURI objectURI: String) -> AltSource? {
		_sources.first { $0.objectID.uriRepresentation().absoluteString == objectURI }
	}

	@ViewBuilder
	private func _appDestination(
		sourceObjectURI: String,
		appLocator: SourcesRouter.AppLocator
	) -> some View {
		if
			let source = _source(withObjectURI: sourceObjectURI),
			let repository = viewModel.repository(for: source)
		{
			SourceAppsDetailView(sourceURL: source.sourceURL, source: repository, app: appLocator.app)
		} else {
			ProgressView()
		}
	}

	private func _unavailableSourceView() -> some View {
		TabPlaceholderView(
			title: .localized("Source Unavailable"),
			description: .localized("This source is no longer available."),
			systemImage: "exclamationmark.triangle"
		)
	}

	private func _resolvePendingNavigationIntent() {
		guard let intent = router.navigationIntent else { return }

		switch intent {
		case .allRepos:
			router.showCollection(.allRepos)
		case .firstSource:
			guard let source = _sources.first else {
				router.navigationIntent = nil
				return
			}
			router.showCollection(.source(objectURI: source.objectID.uriRepresentation().absoluteString))
		case .source(let name):
			let source: AltSource?
			if let name {
				source = _sources.first { $0.name?.localizedCaseInsensitiveContains(name) == true }
			} else {
				source = _sources.first
			}
			guard let source else {
				router.navigationIntent = nil
				return
			}
			router.showCollection(.source(objectURI: source.objectID.uriRepresentation().absoluteString))
		case .app(let sourceName, let appName):
			let source: AltSource?
			if let sourceName {
				source = _sources.first { $0.name?.localizedCaseInsensitiveContains(sourceName) == true }
			} else {
				source = _sources.first
			}
			guard let source else {
				router.navigationIntent = nil
				return
			}
			let objectURI = source.objectID.uriRepresentation().absoluteString
			router.prepareAppNavigation(
				parent: .source(objectURI: objectURI),
				sourceObjectURI: objectURI,
				appName: appName
			)
		}
	}
}
