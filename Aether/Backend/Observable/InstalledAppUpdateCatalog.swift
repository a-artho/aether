import Foundation
import Combine
import AltSourceKit

/// Preferences apply to the installed app, including all source/tweak variants.
@MainActor
final class IgnoredAppUpdates: ObservableObject {
	static let shared = IgnoredAppUpdates()
	private static let key = "Aether.ignoredUpdateBundleIdentifiers"
	private let defaults: UserDefaults
	@Published private(set) var identifiers: Set<String>

	init(defaults: UserDefaults = .standard) {
		self.defaults = defaults
		identifiers = Set(defaults.stringArray(forKey: Self.key) ?? [])
	}

	func ignore(_ identifier: String) {
		guard !identifier.isEmpty, identifiers.insert(identifier).inserted else { return }
		defaults.set(identifiers.sorted(), forKey: Self.key)
	}

	func reset() {
		identifiers = []
		defaults.removeObject(forKey: Self.key)
	}
}

/// Scan loaded catalogs once per source/installed-version change, off the UI thread.
/// Retain only matching updates, never another copy of the entire source catalog.
actor InstalledAppUpdateCatalog {
	static let shared = InstalledAppUpdateCatalog()
	private var signature: [String] = []
	private var cached: [String: [SourceAppCatalogContext]] = [:]
	private var removedSources = Set<String>()

	func clearCache() {
		signature = []
		cached = [:]
	}

	func removeSource(_ key: String) {
		removedSources.insert(key)
		signature = []
		cached = [:]
	}

	func updates(installedVersions: [String: String], contexts: [SourceAppCatalogContext], ignoredIdentifiers: Set<String> = []) throws -> [String: [SourceAppCatalogContext]] {
		try Task.checkCancellation()
		let installedVersions = installedVersions.filter { !ignoredIdentifiers.contains($0.key) }
		guard !installedVersions.isEmpty else { signature = []; cached = [:]; return [:] }
		let contexts = contexts.filter { !removedSources.contains($0.sourceObjectURI) }
		let nextSignature = installedVersions.sorted { $0.key < $1.key }.flatMap { [$0.key, $0.value] }
			+ contexts.flatMap { [$0.sourceObjectURI, $0.sourceURL?.absoluteString ?? "", $0.revision] }
		if signature == nextSignature { return cached }
		var result: [String: [SourceAppCatalogContext]] = [:]
		for context in contexts {
			guard context.sourceURL != nil else { continue }
			var matches: [String: [ASRepository.App]] = [:]
			for app in context.repository.apps {
				try Task.checkCancellation()
				guard let identifier = app.id,
					let url = app.currentDownloadUrl, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
				// Repos may append tweak/version suffixes to the real bundle ID.
				// Walk dot boundaries instead of scanning every installed app;
				// retain the original entry and URL for each separate variant row.
				var candidate = identifier
				while !candidate.isEmpty {
					if let installed = installedVersions[candidate], Self.isNewer(app.currentVersion, than: installed) {
						matches[candidate, default: []].append(app)
					}
					guard let separator = candidate.lastIndex(of: ".") else { break }
					candidate = String(candidate[..<separator])
				}
			}
			for (identifier, apps) in matches {
				var repository = context.repository
				repository.apps = apps
				repository.news = nil
				result[identifier, default: []].append(SourceAppCatalogContext(
					sourceObjectURI: context.sourceObjectURI, sourceURL: context.sourceURL,
					repository: repository, revision: context.revision + "|updates|" + identifier + "|" + installedVersions[identifier, default: ""]))
			}
		}
		try Task.checkCancellation()
		signature = nextSignature
		cached = result
		return result
	}

	/// Missing or unstructured version labels cannot reliably establish an update.
	static func isNewer(_ remote: String?, than installed: String?) -> Bool {
		guard let remote = components(remote), let installed = components(installed) else { return false }
		for offset in 0..<max(remote.count, installed.count) {
			let lhs = offset < remote.count ? remote[offset] : 0
			let rhs = offset < installed.count ? installed[offset] : 0
			if lhs != rhs { return lhs > rhs }
		}
		return false
	}

	private static func components(_ value: String?) -> [UInt64]? {
		guard let value else { return nil }
		let parts = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
		guard !parts.isEmpty else { return nil }
		var numbers: [UInt64] = []
		for part in parts {
			guard !part.isEmpty, part.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let number = UInt64(part) else { return nil }
			numbers.append(number)
		}
		return numbers
	}
}
