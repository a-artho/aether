//
//  SourcesView.swift
//  Aether
//

import CoreData
import AltSourceKit
import SwiftUI
import NimbleViews

struct SourcesView: View {
	@StateObject var viewModel = SourcesViewModel.shared
	@State private var _searchText = ""
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

					NBSection(.localized("Repos")) {
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
			.scrollDismissesKeyboard(.interactively)
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
			.navigationTitle(.localized("Sources"))
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarLeading) {
					Button {
						router.presentAddSource()
					} label: {
						Image(systemName: "plus")
					}
					.accessibilityLabel(.localized("Add Source"))
				}
			}
			.searchable(
				text: $_searchText,
				isPresented: _rootSearchPresented,
				placement: .toolbar,
				prompt: Text(.localized("Search"))
			)
			.searchToolbarBehavior(.minimize)
			.onChange(of: router.searchTarget) { target in
				if target != .root {
					_searchText = ""
				}
			}
			.refreshable {
				await viewModel.fetchSources(_sources, refresh: true)
			}
			.navigationDestination(for: SourcesRouter.Route.self) { route in
				switch route {
				case .collection(.allRepos):
					SourceAppsView(
						object: Array(_sources),
						viewModel: viewModel,
						isAllRepos: true,
						collectionRoute: .allRepos
					)
				case .collection(.source(let objectURI)):
					if let source = _source(withObjectURI: objectURI) {
						SourceAppsView(
							object: [source],
							viewModel: viewModel,
							isAllRepos: false,
							collectionRoute: .source(objectURI: objectURI)
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
		.task(id: Array(_sources)) {
			await viewModel.fetchSources(_sources)
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
			let repository = viewModel.repository(for: source),
			let app = _app(matching: appLocator, in: repository)
		{
			SourceAppsDetailView(sourceURL: source.sourceURL, source: repository, app: app)
		} else {
			ProgressView()
		}
	}

	private func _app(
		matching locator: SourcesRouter.AppLocator,
		in repository: ASRepository
	) -> ASRepository.App? {
		switch locator {
		case .bundleID(let id):
			return repository.apps.first { $0.id == id }
		case .fallback(let name, let developer):
			return repository.apps.first {
				$0.currentName == name && $0.developer == developer
			}
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
