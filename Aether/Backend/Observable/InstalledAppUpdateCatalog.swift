import Foundation
import Combine
import AltSourceKit

/// An exact catalog release, scoped to the installed app whose update was skipped.
/// New versions, builds, URLs, and source variants remain eligible for updates.
struct SkippedAppUpdate: Codable, Hashable, Sendable {
	let repositoryURL: URL
	let appIdentifier: String
	let version: String
	let build: String?
	let downloadURL: URL

	init?(context: SourceAppCatalogContext, app: ASRepository.App) {
		guard let repositoryURL = context.sourceURL, let appIdentifier = app.id,
			let version = app.currentVersion, let downloadURL = app.currentDownloadUrl else { return nil }
		self.repositoryURL = repositoryURL
		self.appIdentifier = appIdentifier
		self.version = version
		self.build = app.currentAppVersion?.build
		self.downloadURL = downloadURL
	}
}

/// Preferences apply to the installed app, including all source/tweak variants.
@MainActor
final class IgnoredAppUpdates: ObservableObject {
	static let shared = IgnoredAppUpdates()
	private static let key = "Aether.ignoredUpdateBundleIdentifiers"
	private static let skippedKey = "Aether.skippedAppUpdateReleases"
	private let defaults: UserDefaults
	@Published private(set) var identifiers: Set<String>
	@Published private(set) var skippedReleases: [String: Set<SkippedAppUpdate>]

	var hasIgnoredUpdates: Bool { !identifiers.isEmpty || !skippedReleases.isEmpty }

	init(defaults: UserDefaults = .standard) {
		self.defaults = defaults
		identifiers = Set(defaults.stringArray(forKey: Self.key) ?? [])
		skippedReleases = defaults.data(forKey: Self.skippedKey)
			.flatMap { try? JSONDecoder().decode([String: Set<SkippedAppUpdate>].self, from: $0) } ?? [:]
	}

	func ignore(_ identifier: String) {
		guard !identifier.isEmpty, identifiers.insert(identifier).inserted else { return }
		defaults.set(identifiers.sorted(), forKey: Self.key)
	}

	/// Capture the releases offered when the user opens Ignore. A release arriving
	/// during the dialog or a later source refresh must not be skipped implicitly.
	func skipCurrentUpdates(for identifier: String, contexts: [SourceAppCatalogContext]) {
		guard !identifier.isEmpty else { return }
		let releases = Set(contexts.flatMap { context in
			context.repository.apps.compactMap { SkippedAppUpdate(context: context, app: $0) }
		})
		guard !releases.isEmpty else { return }
		var next = skippedReleases
		next[identifier, default: []].formUnion(releases)
		guard next != skippedReleases, let data = try? JSONEncoder().encode(next) else { return }
		defaults.set(data, forKey: Self.skippedKey)
		skippedReleases = next
	}

	/// Keep matching caches intact; filter presentation against live preferences.
	/// All entry points (row, latest-version label, and release list) use this view.
	func visibleUpdates(for identifier: String, in contexts: [SourceAppCatalogContext]) -> [SourceAppCatalogContext] {
		guard !identifiers.contains(identifier) else { return [] }
		guard let skipped = skippedReleases[identifier], !skipped.isEmpty else { return contexts }
		return contexts.compactMap { context -> SourceAppCatalogContext? in
			var repository = context.repository
			repository.apps = repository.apps.filter { app in
				guard let release = SkippedAppUpdate(context: context, app: app) else { return true }
				return !skipped.contains(release)
			}
			guard !repository.apps.isEmpty else { return nil }
			guard repository.apps.count != context.repository.apps.count else { return context }
			// SourceAppCatalogContext equality and the update list's grouping cache
			// use revision, so a changed visible subset needs its own revision too.
			let visible = repository.apps.map { app -> String in
				let parts: [String] = [app.id ?? "", app.currentVersion ?? "", app.currentAppVersion?.build ?? "",
					app.currentDownloadUrl?.absoluteString ?? ""]
				return parts.map { "\($0.utf8.count):\($0)" }.joined()
			}.joined(separator: "|")
			return SourceAppCatalogContext(sourceObjectURI: context.sourceObjectURI, sourceURL: context.sourceURL,
				repository: repository, revision: context.revision + "|visible:" + visible)
		}
	}

	func reset() {
		identifiers = []
		skippedReleases = [:]
		defaults.removeObject(forKey: Self.key)
		defaults.removeObject(forKey: Self.skippedKey)
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
		let aetherBundleIdentifiers = Set([
			AetherBuiltInRepository.canonicalBundleIdentifier,
			Bundle.main.bundleIdentifier
		].compactMap { $0 })
		let installedAetherIdentifier = Bundle.main.bundleIdentifier
		var preferredAether: (context: SourceAppCatalogContext, app: ASRepository.App, version: String)?
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
				// Treat canonical and locally renamed Aether IDs as one app. Resolve
				// the highest exact release during this scan; dot-suffixed tweak
				// variants continue through the normal matching path below.
				if aetherBundleIdentifiers.contains(identifier) {
					if let version = app.currentVersion, Self.components(version) != nil {
						let shouldReplace: Bool
						if let current = preferredAether {
							let isSameVersion = !Self.isNewer(version, than: current.version)
								&& !Self.isNewer(current.version, than: version)
							let preferBuiltInTie = isSameVersion
								&& context.sourceObjectURI == AetherBuiltInRepository.key
								&& current.context.sourceObjectURI != AetherBuiltInRepository.key
							shouldReplace = Self.isNewer(version, than: current.version) || preferBuiltInTie
						} else {
							shouldReplace = true
						}
						if shouldReplace {
							preferredAether = (context, app, version)
						}
					}
					continue
				}
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
		if let preferredAether, let installedAetherIdentifier,
			let installedVersion = installedVersions[installedAetherIdentifier],
			Self.isNewer(preferredAether.version, than: installedVersion) {
			var repository = preferredAether.context.repository
			repository.apps = [preferredAether.app]
			repository.news = nil
			result[installedAetherIdentifier, default: []].append(SourceAppCatalogContext(
				sourceObjectURI: preferredAether.context.sourceObjectURI,
				sourceURL: preferredAether.context.sourceURL,
				repository: repository,
				revision: preferredAether.context.revision + "|updates|" + installedAetherIdentifier + "|" + installedVersion
			))
		}
		try Task.checkCancellation()
		signature = nextSignature
		cached = result
		return result
	}

	/// Use numeric version ordering across all matching source variants, rather
	/// than catalog order, release date, or a lexicographic string comparison.
	static func latestVersion(in contexts: [SourceAppCatalogContext], newerThan installed: String?) -> String? {
		var latest: String?
		for context in contexts {
			for app in context.repository.apps {
				guard let version = app.currentVersion, isNewer(version, than: installed) else { continue }
				if latest == nil || isNewer(version, than: latest) { latest = version }
			}
		}
		return latest
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
