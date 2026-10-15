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

// MARK: - Class
@MainActor
final class SourcesViewModel: ObservableObject {
	static let shared = SourcesViewModel()
	
	private let _repositoryService: SourceRepositoryService
	private let _defaults: UserDefaults
	private var _hasStartedGlobalRefresh = false
	private var _lastGlobalAttempt: Date?
	private static let _lastUpdatedKey = "Aether.sourcesLastUpdated"
	@Published private(set) var lastUpdated: Date?
	private var _revisions: [String: String] = [:]
	private var removedSourceKeys = Set<String>()
	private var cacheResetGeneration = UUID()
	@Published private(set) var refreshErrors: [String: String] = [:]
	
	@Published private(set) var catalogRevision = 0
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
		refreshErrors.removeAll()
		_lastGlobalAttempt = nil
		_hasStartedGlobalRefresh = false
		lastUpdated = nil
		_defaults.removeObject(forKey: Self._lastUpdatedKey)
		catalogRevision += 1
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

	/// Keeps the manifest fetched while adding a source so the Sources view does
	/// not immediately download that exact document a second time.
	func cache(_ repository: ASRepository, forIdentifier identifier: String) {
		guard let source = Storage.shared.getSources().first(where: { $0.identifier == identifier }) else {
			return
		}
		let key = source.objectID.uriRepresentation().absoluteString
		guard !removedSourceKeys.contains(key) else { return }
		_revisions[key] = UUID().uuidString
		sources[key] = repository
		catalogRevision += 1
	}

	func cache(_ repositories: [URL: ASRepository]) {
		for (url, repository) in repositories {
			cache(repository, forIdentifier: repository.id ?? url.absoluteString)
		}
	}
	
	func cache(_ snapshot: SourceRepositoryService.Snapshot, for source: AltSource) {
		let key = source.objectID.uriRepresentation().absoluteString
		guard !removedSourceKeys.contains(key) else { return }
		guard _revisions[key] != snapshot.revision else { return }
		_revisions[key] = snapshot.revision
		sources[key] = snapshot.repository
		catalogRevision += 1
	}

	func fetchSources(_ sources: FetchedResults<AltSource>, refresh: Bool = false, batchSize: Int = 4) async {
		await fetchSources(Array(sources), refresh: refresh, batchSize: batchSize)
	}

	func fetchSources(_ sources: [AltSource], refresh: Bool = false, batchSize: Int = 4) async {
		guard isFinished else { return }
		let generation = cacheResetGeneration
		let allRequests = sources.map {
			SourceRequest(key: $0.objectID.uriRepresentation().absoluteString, sourceURL: $0.sourceURL)
		}
		let validKeys = Set(allRequests.map(\.key))
		if self.sources.keys.contains(where: { !validKeys.contains($0) }) {
			self.sources = self.sources.filter { validKeys.contains($0.key) }
			catalogRevision += 1
		}
		_revisions = _revisions.filter { validKeys.contains($0.key) }
		refreshErrors = refreshErrors.filter { validKeys.contains($0.key) }
		let requests = allRequests.filter { refresh || self.sources[$0.key] == nil }
		guard !requests.isEmpty else { return }

		isFinished = false
		defer { isFinished = true }
		await _fetchRequests(requests, refresh: refresh, batchSize: batchSize)
		if refresh, !Task.isCancelled, generation == cacheResetGeneration {
			_hasStartedGlobalRefresh = true
			_lastGlobalAttempt = Date()
			if requests.allSatisfy({ refreshErrors[$0.key] == nil }) {
				lastUpdated = Date()
				_defaults.set(lastUpdated, forKey: Self._lastUpdatedKey)
			}
		}
	}

	/// Check globally once per session, then on foreground after fifteen minutes.
	func refreshIfNeeded(_ sources: [AltSource], now: Date = .now) async {
		guard isFinished, !sources.isEmpty else { return }
		if !_hasStartedGlobalRefresh || now.timeIntervalSince(_lastGlobalAttempt ?? .distantPast) >= 15 * 60 {
			await fetchSources(sources, refresh: true)
		} else {
			await fetchSources(sources)
		}
	}

	/// Navigation uses memory/disk catalogs; only a missing catalog needs a request.
	func ensureSourcesLoaded(_ sources: [AltSource], batchSize: Int = 4) async {
		let generation = cacheResetGeneration
		guard !Task.isCancelled else { return }
		let requests = sources.map {
			SourceRequest(key: $0.objectID.uriRepresentation().absoluteString, sourceURL: $0.sourceURL)
		}
		await _restoreCachedSources(requests)
		guard !Task.isCancelled, generation == cacheResetGeneration else { return }
		let missing = requests.filter { self.sources[$0.key] == nil }
		await _fetchRequests(missing, refresh: false, batchSize: batchSize, restoreCached: false)
	}

	private func _restoreCachedSources(_ requests: [SourceRequest]) async {
		let generation = cacheResetGeneration
		guard !Task.isCancelled else { return }
		let service = _repositoryService
		await withTaskGroup(of: (String, SourceRepositoryService.Snapshot?).self) { group in
			for request in requests where self.sources[request.key] == nil {
				guard !Task.isCancelled else { break }
				group.addTask {
					guard !Task.isCancelled, let url = request.sourceURL else { return (request.key, nil) }
					return (request.key, await service.cached(for: url))
				}
			}
			for await (key, snapshot) in group {
				guard !Task.isCancelled, generation == cacheResetGeneration else { group.cancelAll(); break }
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
		if restoreCached { await _restoreCachedSources(requests) }
		guard generation == cacheResetGeneration else { return }
		let service = _repositoryService
		let size = max(1, batchSize)
		for startIndex in stride(from: 0, to: requests.count, by: size) {
			guard !Task.isCancelled, generation == cacheResetGeneration else { return }
			let batch = requests[startIndex..<min(startIndex + size, requests.count)]
			await withTaskGroup(of: (String, SourceRepositoryService.Snapshot?, String?).self) { group in
				for request in batch {
					group.addTask {
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
				}
				for await (key, snapshot, error) in group {
					guard !Task.isCancelled, generation == cacheResetGeneration else { group.cancelAll(); break }
					guard !removedSourceKeys.contains(key) else { continue }
					refreshErrors[key] = error
					if let snapshot, _revisions[key] != snapshot.revision {
						_revisions[key] = snapshot.revision
						self.sources[key] = snapshot.repository
						catalogRevision += 1
					}
				}
			}
		}
	}
}
