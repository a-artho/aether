import Foundation
import CryptoKit
import AltSourceKit

/// Shares decoded catalogs and HTTP validators across browsing, imports and update checks.
/// This actor keeps JSON decoding and disk work off the main actor.
actor SourceRepositoryService {
	static let shared = SourceRepositoryService()

	struct Snapshot: Sendable {
		let repository: ASRepository
		let revision: String
	}

	private struct StoredCatalog: Codable, Sendable {
		let url: URL
		let data: Data
		let revision: String?
		var etag: String?
		var lastModified: String?
		var checkedAt: Date
		var fullFetchAt: Date
	}

	private struct Entry: Sendable {
		var stored: StoredCatalog
		let snapshot: Snapshot
	}

	private let session: URLSession
	private let cacheDirectory: URL?
	private let recheckInterval: TimeInterval
	private let fullFetchInterval: TimeInterval
	private var entries: [URL: Entry] = [:]
	private var accessOrder: [URL] = []
	private var revisions: [URL: UUID] = [:]
	private var diskReads: [URL: Task<Entry?, Never>] = [:]
	private struct Flight {
		let id = UUID()
		let task: Task<Snapshot, Error>
		let forceFullFetch: Bool
	}
	private var inFlight: [URL: Flight] = [:]

	init(
		session: URLSession? = nil,
		cacheDirectory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
			.first?.appendingPathComponent("SourceCatalogs", isDirectory: true),
		recheckInterval: TimeInterval = 2 * 60,
		fullFetchInterval: TimeInterval = 24 * 60 * 60
	) {
		if let session {
			self.session = session
		} else {
			let configuration = URLSessionConfiguration.ephemeral
			configuration.urlCache = nil
			configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
			configuration.timeoutIntervalForRequest = 30
			self.session = URLSession(configuration: configuration)
		}
		self.cacheDirectory = cacheDirectory
		self.recheckInterval = recheckInterval
		self.fullFetchInterval = fullFetchInterval
	}

	func cached(for url: URL) async -> Snapshot? {
		await loadEntry(for: url)?.snapshot
	}

	/// Explicit refresh always revalidates. Normal consumers may share a recent check.
	func fetch(from url: URL, refresh: Bool = false, forceFullFetch: Bool = false, allowEmptyCatalog: Bool = false) async throws -> Snapshot {
		if let flight = inFlight[url] {
			defer { clearFlight(flight, for: url) }
			let snapshot = try await flight.task.value
			// Finish the shared request before starting a separately requested full fetch.
			if forceFullFetch, !flight.forceFullFetch {
				clearFlight(flight, for: url)
				return try await fetch(from: url, refresh: true, forceFullFetch: true, allowEmptyCatalog: allowEmptyCatalog)
			}
			return try validated(snapshot, allowEmptyCatalog: allowEmptyCatalog)
		}
		if !refresh, !forceFullFetch {
			let entry = await loadEntry(for: url)
			// Disk restoration yields the actor; another consumer may start a request meanwhile.
			if inFlight[url] != nil {
				return try await fetch(from: url, refresh: refresh, allowEmptyCatalog: allowEmptyCatalog)
			}
			if let entry, Date().timeIntervalSince(entry.stored.checkedAt) < recheckInterval {
				return try validated(entry.snapshot, allowEmptyCatalog: allowEmptyCatalog)
			}
		}

		let task = Task { try await self.performFetch(from: url, forceFullFetch: forceFullFetch) }
		let flight = Flight(task: task, forceFullFetch: forceFullFetch)
		inFlight[url] = flight
		defer { clearFlight(flight, for: url) }
		return try validated(await task.value, allowEmptyCatalog: allowEmptyCatalog)
	}

	func remove(_ url: URL) {
		revisions[url] = UUID()
		inFlight.removeValue(forKey: url)?.task.cancel()
		diskReads.removeValue(forKey: url)?.cancel()
		entries[url] = nil
		accessOrder.removeAll { $0 == url }
		if let file = cacheFile(for: url) { try? FileManager.default.removeItem(at: file) }
	}

	func clearCache() {
		// Invalidate suspended reads/fetches before clearing their retained state.
		let urls = Set(entries.keys).union(inFlight.keys).union(diskReads.keys)
		for url in urls { revisions[url] = UUID() }
		for flight in inFlight.values { flight.task.cancel() }
		for read in diskReads.values { read.cancel() }
		inFlight.removeAll()
		diskReads.removeAll()
		entries.removeAll()
		accessOrder.removeAll()
		if let cacheDirectory { try? FileManager.default.removeItem(at: cacheDirectory) }
	}

	private func remember(_ entry: Entry, for url: URL) {
		entries[url] = entry
		accessOrder.removeAll { $0 == url }
		accessOrder.append(url)
		// Bound both catalog count and raw bytes; retain a single large source.
		while entries.count > 8 || (entries.count > 1 && entries.values.reduce(0, { $0 + $1.stored.data.count }) > 32 * 1024 * 1024) {
			guard let victim = accessOrder.first else { break }
			accessOrder.removeFirst()
			entries[victim] = nil
		}
	}

	private func validated(_ snapshot: Snapshot, allowEmptyCatalog: Bool) throws -> Snapshot {
		guard allowEmptyCatalog || !snapshot.repository.apps.isEmpty else {
			throw NSError(domain: "AetherSources", code: 44521, userInfo: [
				NSLocalizedDescriptionKey: "This source does not contain any apps."
			])
		}
		return snapshot
	}

	private nonisolated static func decodeRepository(_ data: Data) throws -> ASRepository {
		let decoder = JSONDecoder()
		decoder.userInfo[ASRepository.allowsEmptyAppsKey] = true
		return try decoder.decode(ASRepository.self, from: data)
	}

	private func clearFlight(_ flight: Flight, for url: URL) {
		if inFlight[url]?.id == flight.id { inFlight[url] = nil }
	}

	private func performFetch(from url: URL, forceFullFetch: Bool) async throws -> Snapshot {
		let revisionToken = revisions[url]
		let previous = await loadEntry(for: url)
		let fullFetchDue = previous.map {
			Date().timeIntervalSince($0.stored.fullFetchAt) >= fullFetchInterval
		} ?? true
		var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
		// Refresh must reach revalidation even when an intermediary has a fresh copy.
		request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
		var conditional = false
		if !forceFullFetch, !fullFetchDue, let previous {
			if let etag = previous.stored.etag {
				request.setValue(etag, forHTTPHeaderField: "If-None-Match")
				conditional = true
			} else if let lastModified = previous.stored.lastModified {
				request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
				conditional = true
			}
		}

		var (data, response) = try await session.data(for: request)
		guard var http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
		if http.statusCode == 304, conditional, var entry = previous {
			entry.stored.checkedAt = Date()
			entry.stored.etag = validETag(http) ?? entry.stored.etag
			entry.stored.lastModified = validLastModified(http) ?? entry.stored.lastModified
			guard revisions[url] == revisionToken, !Task.isCancelled else { throw CancellationError() }
			remember(entry, for: url)
			// Keep this check in memory; rewriting a multi-megabyte disk catalog
			// for a bodyless response would undo much of the refresh saving.
			return entry.snapshot
		}

		// Broken/missing cache state or a server rejecting conditions: retry a plain GET once.
		if http.statusCode == 304 || (conditional && [400, 412, 428].contains(http.statusCode)) {
			request.setValue(nil, forHTTPHeaderField: "If-None-Match")
			request.setValue(nil, forHTTPHeaderField: "If-Modified-Since")
			(data, response) = try await session.data(for: request)
			guard let retryHTTP = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
			http = retryHTTP
		}
		guard http.statusCode == 200 else {
			throw NSError(domain: "AetherSources", code: http.statusCode, userInfo: [
				NSLocalizedDescriptionKey: "Source returned HTTP \(http.statusCode)."
			])
		}

		// Compare bytes before decoding: identical catalogs preserve model identities and UI state.
		let revision = Self.digest(data)
		let snapshot: Snapshot
		let diskData: Data
		if let previous, previous.snapshot.revision == revision {
			snapshot = previous.snapshot
			diskData = previous.stored.data
		} else {
			let repository = try Self.decodeRepository(data)
			snapshot = Snapshot(repository: repository, revision: revision)
			diskData = normalizedCacheData(data, repository: repository)
		}
		// Commit validators only after the body has been validated successfully.
		let stored = StoredCatalog(
			url: url, data: diskData, revision: revision, etag: validETag(http), lastModified: validLastModified(http),
			checkedAt: Date(), fullFetchAt: Date()
		)
		guard revisions[url] == revisionToken, !Task.isCancelled else { throw CancellationError() }
		remember(Entry(stored: stored, snapshot: snapshot), for: url)
		// An unchanged HTTP 200 should not rewrite the complete catalog on every pull.
		// Persist changed validators and the daily full-fetch checkpoint as well.
		if previous?.snapshot.revision != revision || previous?.stored.etag != stored.etag
			|| previous?.stored.lastModified != stored.lastModified || fullFetchDue {
			persist(stored)
		}
		return snapshot
	}

	private func validETag(_ response: HTTPURLResponse) -> String? {
		guard let value = response.value(forHTTPHeaderField: "ETag") else { return nil }
		let tag = value.hasPrefix("W/") ? String(value.dropFirst(2)) : value
		guard tag.count >= 2, tag.first == "\"", tag.last == "\"",
		      !tag.dropFirst().dropLast().contains(where: { $0 == "\"" || $0.isWhitespace || $0.isNewline }) else { return nil }
		return value
	}

	private func validLastModified(_ response: HTTPURLResponse) -> String? {
		guard let value = response.value(forHTTPHeaderField: "Last-Modified") else { return nil }
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.timeZone = TimeZone(secondsFromGMT: 0)
		formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
		formatter.isLenient = false
		return formatter.date(from: value) == nil ? nil : value
	}

	private func loadEntry(for url: URL) async -> Entry? {
		if let entry = entries[url] { remember(entry, for: url); return entry }
		if let read = diskReads[url] {
			let revisionToken = revisions[url]
			let loaded = await read.value
			guard revisions[url] == revisionToken, !read.isCancelled else { return nil }
			return entries[url] ?? loaded
		}
		guard let file = cacheFile(for: url) else { return nil }
		let revisionToken = revisions[url]
		let read = Task.detached(priority: .userInitiated) { () -> Entry? in
			guard let bytes = try? Data(contentsOf: file),
			      let stored = try? PropertyListDecoder().decode(StoredCatalog.self, from: bytes),
			      stored.url == url,
			      let repository = try? Self.decodeRepository(stored.data) else { return nil }
			return Entry(stored: stored, snapshot: Snapshot(repository: repository,
				revision: stored.revision ?? Self.digest(stored.data)))
		}
		diskReads[url] = read
		let loaded = await read.value
		guard revisions[url] == revisionToken else { return nil }
		diskReads[url] = nil
		if let current = entries[url] { return current }
		guard revisions[url] == revisionToken, !Task.isCancelled else { return nil }
		if let loaded { remember(loaded, for: url) }
		return loaded
	}

	/// Persist parsed date timestamps, retaining every other manifest field verbatim.
	/// Reopening avoids repeating tens of thousands of ISO/legacy date parses.
	private func normalizedCacheData(_ data: Data, repository: ASRepository) -> Data {
		guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
		      var apps = root["apps"] as? [[String: Any]], apps.count == repository.apps.count else { return data }
		for index in apps.indices {
			let app = repository.apps[index]
			if let date = app.versionDate { apps[index]["versionDate"] = date.date.timeIntervalSince1970 }
			if let date = app.date { apps[index]["date"] = date.date.timeIntervalSince1970 }
			if var versions = apps[index]["versions"] as? [[String: Any]], let parsed = app.versions,
			   versions.count == parsed.count {
				for versionIndex in versions.indices {
					if let date = parsed[versionIndex].date { versions[versionIndex]["date"] = date.date.timeIntervalSince1970 }
				}
				apps[index]["versions"] = versions
			}
		}
		root["apps"] = apps
		if var news = root["news"] as? [[String: Any]], let parsed = repository.news, news.count == parsed.count {
			for index in news.indices {
				if let date = parsed[index].date { news[index]["date"] = date.date.timeIntervalSince1970 }
			}
			root["news"] = news
		}
		return (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])) ?? data
	}

	private func persist(_ stored: StoredCatalog) {
		guard let cacheDirectory, let file = cacheFile(for: stored.url) else { return }
		do {
			try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
			let encoder = PropertyListEncoder()
			encoder.outputFormat = .binary
			try encoder.encode(stored).write(to: file, options: .atomic)
		} catch {
			// An unavailable/purged disk cache must never prevent refreshing a source.
		}
	}

	private func cacheFile(for url: URL) -> URL? {
		cacheDirectory?.appendingPathComponent(Self.digest(Data(url.absoluteString.utf8)) + ".plist")
	}

	private nonisolated static func digest(_ data: Data) -> String {
		SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
	}
}
