import Foundation
import AltSourceKit

struct InstalledAppUpdateCandidate: Identifiable, Sendable {
	let id: String
	let sourceURL: URL
	let repository: ASRepository
	let app: ASRepository.App
}

struct InstalledAppUpdateDateGroup: Identifiable {
	let date: Date?
	let updates: [InstalledAppUpdateCandidate]
	var id: Date? { date }
}

extension InstalledAppUpdateCandidate {
	static func groupedByDate(_ updates: [Self], calendar: Calendar = .current) -> [InstalledAppUpdateDateGroup] {
		let grouped = Dictionary(grouping: updates) { update in
			(update.app.currentDate?.date).map { calendar.startOfDay(for: $0) }
		}
		return grouped.keys.sorted { lhs, rhs in
			switch (lhs, rhs) {
			case (let lhs?, let rhs?): return lhs > rhs
			case (.some, .none): return true
			default: return false
			}
		}.map { date in
			let rows = grouped[date, default: []].sorted {
				let order = ($0.app.currentVersion ?? "").compare($1.app.currentVersion ?? "", options: .numeric)
				return order == .orderedSame ? $0.id < $1.id : order == .orderedDescending
			}
			return InstalledAppUpdateDateGroup(date: date, updates: rows)
		}
	}
}

/// Shared across detail pages. Catalog indexing runs off the main actor and is
/// rebuilt only when source membership, URLs, or catalog revisions change.
actor InstalledAppUpdateCatalog {
	static let shared = InstalledAppUpdateCatalog()
	private var signature: [String] = []
	private var index: [String: [InstalledAppUpdateCandidate]] = [:]

	func updates(for bundleIdentifier: String, installedVersion: String?, contexts: [SourceAppCatalogContext]) throws -> [InstalledAppUpdateCandidate] {
		try Task.checkCancellation()
		let nextSignature = contexts.flatMap { [$0.sourceObjectURI, $0.sourceURL?.absoluteString ?? "", $0.revision] }
		if nextSignature != signature {
			var nextIndex: [String: [InstalledAppUpdateCandidate]] = [:]
			var seen = Set<String>()
			for context in contexts {
				guard let sourceURL = context.sourceURL else { continue }
				// Rows and detail pages need repository metadata, not another retained catalog.
				var repository = context.repository
				repository.apps = []
				repository.news = nil
				for app in context.repository.apps {
					try Task.checkCancellation()
					guard let bundleID = app.id, !bundleID.isEmpty,
						let version = app.currentVersion,
						let downloadURL = app.currentDownloadUrl,
						["https", "http"].contains(downloadURL.scheme?.lowercased() ?? "")
					else { continue }
					let id = [context.sourceObjectURI, bundleID, version, downloadURL.absoluteString].joined(separator: "\u{1F}")
					guard seen.insert(id).inserted else { continue }
					nextIndex[bundleID, default: []].append(InstalledAppUpdateCandidate(
						id: id, sourceURL: sourceURL, repository: repository, app: app
					))
				}
			}
			signature = nextSignature
			index = nextIndex
		}
		return (index[bundleIdentifier] ?? []).filter {
			Self.isNewer($0.app.currentVersion, than: installedVersion)
		}.sorted {
			let order = ($0.app.currentVersion ?? "").compare($1.app.currentVersion ?? "", options: .numeric)
			return order == .orderedSame ? $0.id < $1.id : order == .orderedDescending
		}
	}

	/// One indexed pass for all visible installed apps; no per-row catalog scans.
	func bundleIdentifiersWithUpdates(installedVersions: [String: String], contexts: [SourceAppCatalogContext]) throws -> Set<String> {
		guard let first = installedVersions.first else { return [] }
		_ = try updates(for: first.key, installedVersion: first.value, contexts: contexts)
		var result = Set<String>()
		for (identifier, version) in installedVersions {
			try Task.checkCancellation()
			if (index[identifier] ?? []).contains(where: { Self.isNewer($0.app.currentVersion, than: version) }) {
				result.insert(identifier)
			}
		}
		return result
	}

	/// Compare numeric dotted versions without treating 1.2.0 as newer than 1.2.
	/// Unstructured labels and missing versions cannot establish an update.
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
