//
//  AppStoreLookup.swift
//  Feather
//

import Foundation

struct AppStoreDestination: Equatable {
	let url: URL
	let isDirectMatch: Bool

	var buttonTitle: String {
		isDirectMatch ? .localized("View on App Store") : .localized("Search App Store")
	}
}

actor AppStoreLookup {
	static let shared = AppStoreLookup()
	private var cache: [LookupKey: AppStoreDestination] = [:]

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

		if let cachedDestination = cache[key] {
			return cachedDestination
		}

		if let bundleID = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines), !bundleID.isEmpty,
		   let entry = await _lookup(bundleID: bundleID)
		{
			let destination = AppStoreDestination(url: entry, isDirectMatch: true)
			cache[key] = destination
			return destination
		}

		for query in _searchQueries(for: name) {
			guard let entries = await _search(query: query) else { continue }
			if let entry = _bestNameMatch(in: entries, for: query) {
				let destination = AppStoreDestination(url: entry, isDirectMatch: true)
				cache[key] = destination
				return destination
			}
		}

		let destination = _searchDestination(for: _searchQueries(for: name).first ?? name)
		if let destination {
			cache[key] = destination
		}
		return destination
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

	private func _searchQueries(for name: String) -> [String] {
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

	private func _searchDestination(for query: String) -> AppStoreDestination? {
		guard var components = URLComponents(string: "itms-apps://itunes.apple.com/search") else { return nil }
		components.queryItems = [URLQueryItem(name: "term", value: query)]
		guard let url = components.url else { return nil }
		return AppStoreDestination(url: url, isDirectMatch: false)
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
