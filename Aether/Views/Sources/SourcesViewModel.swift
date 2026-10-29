//
//  SourcesViewModel.swift
//  Aether
//
//  Created by samara on 30.04.2025.
//

import Foundation
import AltSourceKit
import SwiftUI
import OSLog

enum AetherBuiltInRepository {
	static let key = "builtin:aether"
	static let canonicalBundleIdentifier = "com.anfear.aether"
	static let url = URL(string: "https://raw.githubusercontent.com/a-artho/aether/main/app-repo.json")!
}

// MARK: - Class
@MainActor
final class SourcesViewModel: ObservableObject {
	static let shared = SourcesViewModel()
	
	private let _repositoryService: SourceRepositoryService
	private let _defaults: UserDefaults
	private var _lastGlobalAttempt: Date?
	private var _lastBuiltInAttempt: Date?
	private static let _lastUpdatedKey = "Aether.sourcesLastUpdated"
	@Published private(set) var lastUpdated: Date?
	private var _revisions: [String: String] = [:]
	private var removedSourceKeys = Set<String>()
	private var cacheResetGeneration = UUID()
	@Published private(set) var refreshErrors: [String: String] = [:]
	/// Kept separate from user repositories so this catalog never appears in Sources.
	@Published private(set) var builtInAetherSnapshot: SourceRepositoryService.Snapshot?
	
	@Published private(set) var catalogRevision = 0
	@Published private(set) var cacheGeneration = 0
	@Published private(set) var isRefreshRequested = false
	@Published private var sourceRefreshOwners: [String: Set<UUID>] = [:]
	private var requestedRefreshTask: Task<Void, Never>?

	func isRefreshing(_ source: AltSource) -> Bool {
		sourceRefreshOwners[source.objectID.uriRepresentation().absoluteString]?.isEmpty == false
	}

	/// Own user-triggered refresh independently of the pull control's short animation.
	@discardableResult
	func startRefresh(_ sources: [AltSource]) -> Task<Void, Never> {
		if let requestedRefreshTask { return requestedRefreshTask }
		isRefreshRequested = true
		let task = Task { @MainActor in
			defer { requestedRefreshTask = nil; isRefreshRequested = false }
			if !isFinished {
				let previousAttempt = _lastGlobalAttempt
				let (changes, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
				let observation = $isFinished.sink { continuation.yield($0) }
				defer { observation.cancel(); continuation.finish() }
				for await finished in changes {
					if Task.isCancelled { return }
					if finished { break }
				}
				// Join an already-running global refresh instead of fetching it twice.
				if _lastGlobalAttempt != previousAttempt { return }
			}
			await fetchSources(sources, refresh: true)
		}
		requestedRefreshTask = task
		return task
	}

	@Published private(set) var isFinished = true
	@Published private(set) var sources: [String: ASRepository] = [:]

	private struct SourceRequest: Sendable {
		let key: String
		let sourceURL: URL?
	}

	init(repositoryService: SourceRepositoryService = .shared, defaults: UserDefaults = .standard) {
		_repositoryService = repositoryService
		_defaults = defaults
		lastUpdated = defaults.object(forKey: Self._lastUpdatedKey) as? Date
	}

	func clearNetworkCache() async {
		cacheResetGeneration = UUID()
		await _repositoryService.clearCache()
		await SourceAppListStore.shared.clearCache()
		await InstalledAppUpdateCatalog.shared.clearCache()
		_revisions.removeAll()
		sources.removeAll()
		builtInAetherSnapshot = nil
		refreshErrors.removeAll()
		_lastGlobalAttempt = nil
		_lastBuiltInAttempt = nil
		lastUpdated = nil
		_defaults.removeObject(forKey: Self._lastUpdatedKey)
		catalogRevision += 1
		cacheGeneration += 1
	}

	func removeSource(key: String, url: URL?, evictURL: Bool) {
		removedSourceKeys.insert(key)
		sources[key] = nil
		_revisions[key] = nil
		refreshErrors[key] = nil
		catalogRevision += 1
		Task {
			await SourceAppListStore.shared.removeSource(key)
			await InstalledAppUpdateCatalog.shared.removeSource(key)
			if evictURL, let url { await _repositoryService.remove(url) }
		}
	}

	func revision(for source: AltSource) -> String {
		_revisions[source.objectID.uriRepresentation().absoluteString] ?? "unloaded"
	}

	func repository(for source: AltSource) -> ASRepository? {
		sources[source.objectID.uriRepresentation().absoluteString]
	}

	/// Rebind only Aether's canonical release entry to this installation's identity.
	/// This supports developer-signed or otherwise renamed Aether builds while
	/// leaving every other app in the manifest untouched.
	func builtInAetherUpdateContext(installedBundleIdentifier: String?) -> SourceAppCatalogContext? {
		guard let installedBundleIdentifier,
			let snapshot = builtInAetherSnapshot else { return nil }
		var repository = snapshot.repository
		let aetherApps = repository.apps.compactMap { app -> ASRepository.App? in
			guard app.id == AetherBuiltInRepository.canonicalBundleIdentifier else { return nil }
			var rebound = app
			rebound.id = installedBundleIdentifier
			return rebound
		}
		guard !aetherApps.isEmpty else { return nil }
		repository.apps = aetherApps
		return SourceAppCatalogContext(
			sourceObjectURI: AetherBuiltInRepository.key,
			sourceURL: AetherBuiltInRepository.url,
			repository: repository,
			revision: snapshot.revision
		)
	}

	/// Preserve the HTTP content revision; adding a source must not manufacture a
	/// second catalog revision or prepare browsing rows during update-only work.
	func cache(_ snapshot: SourceRepositoryService.Snapshot, forIdentifier identifier: String) {
		guard let source = Storage.shared.getSources().first(where: { $0.identifier == identifier }) else { return }
		cache(snapshot, for: source)
	}

	func cache(_ snapshots: [URL: SourceRepositoryService.Snapshot]) {
		let sources = Storage.shared.getSources()
		for (url, snapshot) in snapshots {
			let identifier = snapshot.repository.id ?? url.absoluteString
			guard let source = sources.first(where: { $0.identifier == identifier && $0.sourceURL == url }) else { continue }
			cache(snapshot, for: source)
		}
	}

	func cache(_ snapshot: SourceRepositoryService.Snapshot, for source: AltSource) {
		let key = source.objectID.uriRepresentation().absoluteString
		guard !source.isDeleted, !removedSourceKeys.contains(key), _revisions[key] != snapshot.revision else { return }
		_revisions[key] = snapshot.revision
		sources[key] = snapshot.repository
		refreshErrors[key] = nil
		catalogRevision += 1
	}

	func fetchSources(_ sources: FetchedResults<AltSource>, refresh: Bool = false, batchSize: Int = 4) async {
		await fetchSources(Array(sources), refresh: refresh, batchSize: batchSize)
	}

	func fetchSources(_ sources: [AltSource], refresh: Bool = false, batchSize: Int = 4) async {
		guard isFinished else { return }
		let generation = cacheResetGeneration
		let userRequests = _userRequests(sources)
		let validKeys = Set(userRequests.map(\.key))
		if self.sources.keys.contains(where: { !validKeys.contains($0) }) {
			self.sources = self.sources.filter { validKeys.contains($0.key) }
			catalogRevision += 1
		}
		_revisions = _revisions.filter { validKeys.contains($0.key) }
		refreshErrors = refreshErrors.filter { validKeys.contains($0.key) }
		let requests = _requests(for: userRequests, refresh: refresh)
		guard !requests.isEmpty else { return }

		isFinished = false
		defer { isFinished = true }
		await _fetchRequests(requests, refresh: refresh, batchSize: batchSize)
		if refresh, !Task.isCancelled, generation == cacheResetGeneration {
			_lastGlobalAttempt = Date()
			// The hidden Aether feed is optional and must not affect the user's
			// repository status or make an otherwise successful refresh look failed.
			if !userRequests.isEmpty && userRequests.allSatisfy({ refreshErrors[$0.key] == nil }) {
				lastUpdated = Date()
				_defaults.set(lastUpdated, forKey: Self._lastUpdatedKey)
			}
		}
	}

	/// Automatic refreshes share a two-minute freshness window, including relaunches.
	func refreshIfNeeded(_ sources: [AltSource], now: Date = .now) async {
		guard !Task.isCancelled, isFinished, !isRefreshRequested else { return }
		if now.timeIntervalSince(_lastGlobalAttempt ?? lastUpdated ?? .distantPast) >= 2 * 60 {
			// The page may disappear or become inactive while the request is in
			// flight. Shared ownership keeps catalog and timestamp commits together.
			await startRefresh(sources).value
		} else {
			await ensureSourcesLoaded(sources)
		}
	}

	/// Navigation uses memory/disk catalogs; only a missing catalog needs a request.
	func ensureSourcesLoaded(_ sources: [AltSource], batchSize: Int = 4) async {
		let generation = cacheResetGeneration
		guard !Task.isCancelled else { return }
		let requests = _requests(for: _userRequests(sources), refresh: false)
		await _restoreCachedSources(requests)
		guard !Task.isCancelled, generation == cacheResetGeneration else { return }
		let missing = requests.filter { !_hasCatalog(for: $0.key) }
		await _fetchRequests(missing, refresh: false, batchSize: batchSize, restoreCached: false)
	}

	private func _userRequests(_ sources: [AltSource]) -> [SourceRequest] {
		sources.map {
			SourceRequest(key: $0.objectID.uriRepresentation().absoluteString, sourceURL: $0.sourceURL)
		}
	}

	/// One request builder keeps manual refresh, automatic refresh, and lazy cache
	/// restoration aligned while keeping the internal feed out of Core Data.
	private func _requests(for userRequests: [SourceRequest], refresh: Bool) -> [SourceRequest] {
		var requests = userRequests.filter { refresh || self.sources[$0.key] == nil }
		let builtInRetryIsDue = _lastBuiltInAttempt.map { Date().timeIntervalSince($0) >= 2 * 60 } ?? true
		if refresh || (builtInAetherSnapshot == nil && builtInRetryIsDue) {
			requests.append(SourceRequest(key: AetherBuiltInRepository.key, sourceURL: AetherBuiltInRepository.url))
		}
		return requests
	}

	private func _hasCatalog(for key: String) -> Bool {
		key == AetherBuiltInRepository.key ? builtInAetherSnapshot != nil : sources[key] != nil
	}

	private func _publishBuiltInAether(_ snapshot: SourceRepositoryService.Snapshot) {
		guard builtInAetherSnapshot?.revision != snapshot.revision else { return }
		builtInAetherSnapshot = snapshot
		catalogRevision += 1
	}

	private func _restoreCachedSources(_ requests: [SourceRequest]) async {
		let generation = cacheResetGeneration
		guard !Task.isCancelled else { return }
		let service = _repositoryService
		let pending = requests.filter { !_hasCatalog(for: $0.key) }
		await withTaskGroup(of: (String, SourceRepositoryService.Snapshot?).self) { group in
			var next = 0
			func enqueue(_ request: SourceRequest) {
				group.addTask {
					guard !Task.isCancelled, let url = request.sourceURL else { return (request.key, nil) }
					return (request.key, await service.cached(for: url))
				}
			}
			for request in pending.prefix(4) { enqueue(request); next += 1 }
			for await (key, snapshot) in group {
				guard !Task.isCancelled, generation == cacheResetGeneration else { group.cancelAll(); break }
				if next < pending.count { enqueue(pending[next]); next += 1 }
				if let snapshot, key == AetherBuiltInRepository.key {
					guard !_hasCatalog(for: key) else { continue }
					_publishBuiltInAether(snapshot)
					continue
				}
				if let snapshot, !removedSourceKeys.contains(key), self.sources[key] == nil {
					_revisions[key] = snapshot.revision
					self.sources[key] = snapshot.repository
					catalogRevision += 1
				}
			}
		}
	}

	private func _fetchRequests(_ requests: [SourceRequest], refresh: Bool, batchSize: Int, restoreCached: Bool = true) async {
		let generation = cacheResetGeneration
		guard !Task.isCancelled else { return }
		var ownersByKey: [String: UUID] = [:]
		for request in requests {
			let owner = UUID()
			ownersByKey[request.key] = owner
			sourceRefreshOwners[request.key, default: []].insert(owner)
		}
		func finishRefreshOwner(for key: String) {
			guard let owner = ownersByKey.removeValue(forKey: key) else { return }
			sourceRefreshOwners[key]?.remove(owner)
			if sourceRefreshOwners[key]?.isEmpty == true { sourceRefreshOwners[key] = nil }
		}
		defer {
			for key in Array(ownersByKey.keys) { finishRefreshOwner(for: key) }
		}
		if restoreCached { await _restoreCachedSources(requests) }
		guard generation == cacheResetGeneration else { return }
		let service = _repositoryService
		let size = max(1, batchSize)
		let fetch: @Sendable (SourceRequest) async -> (String, SourceRepositoryService.Snapshot?, String?) = { request in
			guard !Task.isCancelled else { return (request.key, nil, nil) }
			guard let url = request.sourceURL else { return (request.key, nil, "Invalid source URL.") }
			do {
				return (request.key, try await service.fetch(from: url, refresh: refresh, allowEmptyCatalog: true), nil)
			} catch is CancellationError {
				return (request.key, nil, nil)
			} catch {
				guard !Task.isCancelled else { return (request.key, nil, nil) }
				Logger.misc.error("Source refresh failed: \(url.absoluteString): \(error.localizedDescription)")
				return (request.key, nil, error.localizedDescription)
			}
		}
		await withTaskGroup(of: (String, SourceRepositoryService.Snapshot?, String?).self) { group in
			var nextIndex = 0
			for request in requests.prefix(size) {
				group.addTask { await fetch(request) }
				nextIndex += 1
			}
			for await (key, snapshot, error) in group {
				defer { finishRefreshOwner(for: key) }
				guard !Task.isCancelled, generation == cacheResetGeneration else { group.cancelAll(); break }
				if nextIndex < requests.count {
					let request = requests[nextIndex]
					nextIndex += 1
					group.addTask { await fetch(request) }
				}
				if key == AetherBuiltInRepository.key {
					_lastBuiltInAttempt = Date()
					if let snapshot {
						_publishBuiltInAether(snapshot)
					} else if let error {
						// GitHub returns an unauthenticated 404 while this repository is
						// private. Log it for diagnosis, but keep it out of source errors.
						Logger.misc.notice("Built-in Aether update feed unavailable: \(error, privacy: .public)")
					}
					continue
				}
				guard !removedSourceKeys.contains(key) else { continue }
				if let snapshot, (_revisions[key] != snapshot.revision || self.sources[key] == nil) {
					_revisions[key] = snapshot.revision
					self.sources[key] = snapshot.repository
					refreshErrors[key] = nil
					catalogRevision += 1
				} else {
					refreshErrors[key] = error
				}
			}
		}
	}

}
