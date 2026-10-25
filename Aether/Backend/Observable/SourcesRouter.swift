//
//  SourcesRouter.swift
//  Aether
//

import SwiftUI
import AltSourceKit

@MainActor
final class SourcesRouter: ObservableObject {
	static let shared = SourcesRouter()

	enum CollectionRoute: Hashable {
		case allRepos
		case source(objectURI: String)
	}

	enum Route: Hashable {
		case collection(CollectionRoute)
		case app(
			parent: CollectionRoute,
			sourceObjectURI: String,
			appLocator: AppLocator
		)
	}

	struct AppLocator: Hashable {
		// A bundle identifier is shared by versions and tweak variants. Keep the
		// selected catalog snapshot so refreshes cannot silently change the target.
		let app: ASRepository.App

		static func locator(for app: ASRepository.App) -> AppLocator {
			AppLocator(app: app)
		}
	}

	enum NavigationIntent: Equatable {
		case allRepos
		case firstSource
		case source(name: String?)
		case app(sourceName: String?, appName: String?)
	}

	enum SearchTarget: Hashable {
		case root
		case collection(CollectionRoute)
	}

	struct PendingAppRequest: Equatable {
		let parent: CollectionRoute
		let sourceObjectURI: String
		let appName: String?
	}

	struct AddSourceRequest: Identifiable, Equatable {
		let id: UUID
		let initialURL: String

		init(initialURL: String) {
			self.id = UUID()
			self.initialURL = initialURL
		}
	}

	@Published var path: [Route] = [] {
		didSet {
			_reconcileSearchTarget()
			_reconcilePendingAppRequest()
		}
	}
	@Published var navigationIntent: NavigationIntent?
	@Published var pendingAppRequest: PendingAppRequest?
	@Published var searchTarget: SearchTarget?
	@Published var addSourceRequest: AddSourceRequest?

	private init() {}

	func requestNavigation(_ intent: NavigationIntent) {
		navigationIntent = intent
	}

	func presentAddSource(initialURL: String = "") {
		addSourceRequest = AddSourceRequest(initialURL: initialURL)
	}

	func showCollection(_ collection: CollectionRoute) {
		navigationIntent = nil
		pendingAppRequest = nil
		searchTarget = nil
		path = [.collection(collection)]
	}

	func prepareAppNavigation(
		parent: CollectionRoute,
		sourceObjectURI: String,
		appName: String?
	) {
		navigationIntent = nil
		searchTarget = nil
		pendingAppRequest = PendingAppRequest(
			parent: parent,
			sourceObjectURI: sourceObjectURI,
			appName: appName
		)
		path = [.collection(parent)]
	}

	func openResolvedApp(
		parent: CollectionRoute,
		sourceObjectURI: String,
		appLocator: AppLocator
	) {
		pendingAppRequest = nil

		let appRoute = Route.app(
			parent: parent,
			sourceObjectURI: sourceObjectURI,
			appLocator: appLocator
		)
		// Check before changing the path: resetting to the parent first makes this
		// guard ineffective when the same detail route is already visible.
		guard path.last != appRoute else { return }

		let parentRoute = Route.collection(parent)
		if path.last != parentRoute {
			path = [parentRoute]
		}
		path.append(appRoute)
	}

	func openSearchForVisibleScreen() {
		switch path.last {
		case nil:
			searchTarget = .root
		case .collection(let collection):
			searchTarget = .collection(collection)
		case .app:
			break
		}
	}

	func closeSearch() {
		searchTarget = nil
	}

	private func _reconcileSearchTarget() {
		guard let searchTarget else { return }

		switch searchTarget {
		case .root:
			if !path.isEmpty {
				self.searchTarget = nil
			}
		case .collection(let collection):
			// Keep the parent search session while its app details are on the stack.
			if !path.contains(.collection(collection)) {
				self.searchTarget = nil
			}
		}
	}

	private func _reconcilePendingAppRequest() {
		guard let request = pendingAppRequest else { return }
		guard path.last == .collection(request.parent) else {
			pendingAppRequest = nil
			return
		}
	}
}
