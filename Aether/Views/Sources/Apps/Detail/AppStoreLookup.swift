//
//  AppStoreLookup.swift
//  Aether
//

import Foundation

struct AppStoreDestination: Equatable {
	let url: URL

}

actor AppStoreLookup {
	static let shared = AppStoreLookup()
	private var cache: [LookupKey: (destination: AppStoreDestination, expires: Date)] = [:]
	private struct Flight {
        let id: UUID
        let task: Task<AppStoreDestination?, Never>
        var consumers: Set<UUID>
    }
    private var inFlight: [LookupKey: Flight] = [:]

	/// Available before network resolution so the information row never appears late.
	nonisolated static func fallbackDestination(appName: String) -> AppStoreDestination? {
		let name = appName.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !name.isEmpty else { return nil }
		return _searchDestination(for: _searchQueries(for: name).first ?? name)
	}

	private struct LookupKey: Hashable {
		let bundleID: String
		let appName: String
	}

	private struct Response: Decodable {
		let results: [Entry]
	}

	private struct Entry: Decodable {
		let bundleId: String?
		let trackName: String?
		let trackViewUrl: URL?
	}

	func destination(bundleID: String?, appName: String) async -> AppStoreDestination? {
		let name = appName.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !name.isEmpty else { return nil }
		let key = LookupKey(bundleID: bundleID ?? "", appName: name)

		if let cached = cache[key], cached.expires > Date() { return cached.destination }
        guard !Task.isCancelled else { return nil }
        let consumer = UUID()
        let flight: Flight
        if var existing = inFlight[key] {
            existing.consumers.insert(consumer)
            inFlight[key] = existing
            flight = existing
        } else {
            flight = Flight(id: UUID(), task: Task { await self.resolve(bundleID: bundleID, name: name) }, consumers: [consumer])
            inFlight[key] = flight
        }
        let result = await withTaskCancellationHandler { await flight.task.value } onCancel: {
            Task { await self.release(key: key, flightID: flight.id, consumer: consumer) }
        }
        if let result, !flight.task.isCancelled {
            if cache.count >= 256, let victim = cache.keys.first { cache.removeValue(forKey: victim) }
            cache[key] = (result, Date().addingTimeInterval(300))
        }
        release(key: key, flightID: flight.id, consumer: consumer)
        return Task.isCancelled ? nil : result
    }

    private func release(key: LookupKey, flightID: UUID, consumer: UUID) {
        guard var flight = inFlight[key], flight.id == flightID else { return }
        flight.consumers.remove(consumer)
        if flight.consumers.isEmpty { inFlight[key] = nil; flight.task.cancel() }
        else { inFlight[key] = flight }
    }

    private func resolve(bundleID: String?, name: String) async -> AppStoreDestination? {
        if let bundleID, !bundleID.isEmpty, let entry = await _lookup(bundleID: bundleID) {
            return AppStoreDestination(url: entry)
        }
        for query in Self._searchQueries(for: name) {
            guard !Task.isCancelled else { return nil }
            guard let entries = await _search(query: query) else { continue }
            if let entry = _bestNameMatch(in: entries, for: query) { return AppStoreDestination(url: entry) }
        }
        return Task.isCancelled ? nil : Self.fallbackDestination(appName: name)
    }

	private func _lookup(bundleID: String) async -> URL? {
		guard var components = URLComponents(string: "https://itunes.apple.com/lookup") else { return nil }
		components.queryItems = [URLQueryItem(name: "bundleId", value: bundleID)]
		return await _request(components.url)?.results.first {
			$0.bundleId?.caseInsensitiveCompare(bundleID) == .orderedSame
		}?.trackViewUrl
	}

	private func _search(query: String) async -> [Entry]? {
		guard var components = URLComponents(string: "https://itunes.apple.com/search") else { return nil }
		components.queryItems = [
			URLQueryItem(name: "term", value: query),
			URLQueryItem(name: "entity", value: "software"),
			URLQueryItem(name: "limit", value: "10")
		]
		return await _request(components.url)?.results
	}

	private func _request(_ url: URL?) async -> Response? {
		guard let url else { return nil }

		do {
			let (data, response) = try await URLSession.shared.data(from: url)
			guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { return nil }
			return try JSONDecoder().decode(Response.self, from: data)
		} catch {
			return nil
		}
	}

	private func _bestNameMatch(in entries: [Entry], for query: String) -> URL? {
		let normalizedQuery = _normalized(query)
		guard normalizedQuery.count >= 4 else { return nil }

		return entries.first { entry in
			guard let name = entry.trackName, entry.trackViewUrl != nil else { return false }
			let normalizedName = _normalized(name)
			return normalizedName == normalizedQuery ||
				normalizedName.count >= 4 && normalizedQuery.contains(normalizedName)
		}?.trackViewUrl
	}

	nonisolated private static func _searchQueries(for name: String) -> [String] {
		let normalizedSeparators = name.replacingOccurrences(of: "_", with: " ")
		let versionSuffix = try? NSRegularExpression(pattern: #"(?i)(?:\s|-)+v?\d+(?:\.\d+)+(?:\s.*)?$"#)
		let range = NSRange(normalizedSeparators.startIndex..., in: normalizedSeparators)
		let cleaned = versionSuffix?
			.stringByReplacingMatches(in: normalizedSeparators, range: range, withTemplate: "")
			.trimmingCharacters(in: .whitespacesAndNewlines)

		return [cleaned, normalizedSeparators]
			.compactMap { $0?.isEmpty == false ? $0 : nil }
			.removingDuplicates()
	}

	nonisolated private static func _searchDestination(for query: String) -> AppStoreDestination? {
		guard var components = URLComponents(string: "itms-apps://itunes.apple.com/search") else { return nil }
		components.queryItems = [URLQueryItem(name: "term", value: query)]
		guard let url = components.url else { return nil }
		return AppStoreDestination(url: url)
	}

	private func _normalized(_ value: String) -> String {
		value
			.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
			.unicodeScalars
			.filter(CharacterSet.alphanumerics.contains)
			.map(String.init)
			.joined()
	}
}

private extension Array where Element: Hashable {
	func removingDuplicates() -> [Element] {
		var seen = Set<Element>()
		return filter { seen.insert($0).inserted }
	}
}
