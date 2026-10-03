import Foundation
import CryptoKit
import AltSourceKit

struct SourceAppCatalogContext: Sendable, Equatable {
	let sourceObjectURI: String
	let sourceURL: URL?
	let repository: ASRepository
	let revision: String

	static func == (lhs: Self, rhs: Self) -> Bool {
		lhs.sourceObjectURI == rhs.sourceObjectURI && lhs.sourceURL == rhs.sourceURL && lhs.revision == rhs.revision
	}
}

struct SourceAppRowID: Hashable, Sendable {
	let source: String
	let identity: String
	let occurrence: Int
}

struct SourceAppRow: Sendable {
	let id: SourceAppRowID
	let sourceObjectURI: String
	let sourceURL: URL?
	let source: ASRepository
	let app: ASRepository.App
	let contentRevision: Int
	let name: String
	let bundleID: String
	let date: Date?
	let letter: String
}

struct PreparedSourceAppList: Sendable {
	struct Section: Sendable {
		let title: String
		let rows: [SourceAppRowID]
	}
	let sections: [Section]
	let rows: [SourceAppRowID: SourceAppRow]

	/// Content changes exclude random decoder UUIDs. UIKit keeps unchanged cells alive.
	func changedRows(comparedTo previous: Self?) -> [SourceAppRowID] {
		guard let previous else { return [] }
		return rows.compactMap { id, row in
			guard let old = previous.rows[id], old.contentRevision != row.contentRevision else { return nil }
			return id
		}
	}
}

/// Reuses catalog projections and sorted section indexes across navigation and app launches.
/// Filtering, sorting, hashing, grouping and disk access all run on this actor, away from UI work.
actor SourceAppListStore {
	static let shared = SourceAppListStore()
	private struct Key: Hashable, Codable {
		let sources: [String]
		let sort: String
		let ascending: Bool
		let locale: String
		let timeZone: String
		let unknownDate: String
		var formatVersion = 1
	}
	private struct Order: Codable {
		struct Section: Codable { let title: String; let indices: [Int] }
		let key: Key
		let sections: [Section]
	}
	private struct Projection {
		let key: [String]
		let rows: [SourceAppRow]
	}
	private let cacheDirectory: URL?
	private var projections: [String: Projection] = [:]
	private var prepared: [Key: PreparedSourceAppList] = [:]

	init(cacheDirectory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
		.first?.appendingPathComponent("SourceListIndexes", isDirectory: true)) {
		self.cacheDirectory = cacheDirectory
	}

	func list(
		contexts: [SourceAppCatalogContext], sort: String, ascending: Bool,
		query: String, unknownDate: String
	) throws -> PreparedSourceAppList {
		try Task.checkCancellation()
		let sourceKeys = contexts.flatMap { [$0.sourceObjectURI, $0.sourceURL?.absoluteString ?? "", $0.revision] }
		let key = Key(sources: sourceKeys, sort: sort, ascending: ascending,
			locale: Locale.current.identifier, timeZone: TimeZone.current.identifier, unknownDate: unknownDate)
		let base: PreparedSourceAppList
		if let cached = prepared[key] {
			base = cached
		} else {
			let rows = try contexts.flatMap { try projection(for: $0) }
			let storedOrder = loadOrder(key: key, count: rows.count)
			let order = storedOrder ?? makeOrder(rows: rows, key: key)
			try Task.checkCancellation()
			base = PreparedSourceAppList(
				sections: order.sections.map { .init(title: $0.title, rows: $0.indices.map { rows[$0].id }) },
				rows: Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
			)
			// Superseded catalog revisions must not accumulate large retained app graphs.
			prepared = prepared.filter { old, _ in
				old.sources.enumerated().filter { $0.offset % 3 == 0 }.map(\.element)
					!= key.sources.enumerated().filter { $0.offset % 3 == 0 }.map(\.element)
				|| old.sources == key.sources
			}
			if prepared.count >= 8, let oldest = prepared.keys.first { prepared[oldest] = nil }
			prepared[key] = base
			if storedOrder == nil { persist(order) }
		}
		guard !query.isEmpty else { return base }

		let locale = Locale(identifier: "en_US")
		var sections: [PreparedSourceAppList.Section] = []
		var matches: [SourceAppRowID: SourceAppRow] = [:]
		for section in base.sections {
			var ids: [SourceAppRowID] = []
			for (index, id) in section.rows.enumerated() {
				if index % 256 == 0 { try Task.checkCancellation() }
				guard let row = base.rows[id] else { continue }
				let app = row.app
				if app.id?.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: locale) != nil
					|| app.name?.localizedCaseInsensitiveContains(query) == true
					|| app.description?.localizedCaseInsensitiveContains(query) == true
					|| app.subtitle?.localizedCaseInsensitiveContains(query) == true
					|| app.localizedDescription?.localizedCaseInsensitiveContains(query) == true {
					ids.append(id)
					matches[id] = row
				}
			}
			if !ids.isEmpty { sections.append(.init(title: section.title, rows: ids)) }
		}
		return PreparedSourceAppList(sections: sections, rows: matches)
	}

	func changedRows(in list: PreparedSourceAppList, comparedTo previous: PreparedSourceAppList?) -> [SourceAppRowID] {
		list.changedRows(comparedTo: previous)
	}

	private func projection(for context: SourceAppCatalogContext) throws -> [SourceAppRow] {
		let key = [context.revision, context.sourceURL?.absoluteString ?? ""]
		if let cached = projections[context.sourceObjectURI], cached.key == key { return cached.rows }
		var occurrences: [String: Int] = [:]
		var rows: [SourceAppRow] = []
		rows.reserveCapacity(context.repository.apps.count)
		for (index, app) in context.repository.apps.enumerated() {
			if index % 256 == 0 { try Task.checkCancellation() }
			// Repositories contain many versions with the same bundle ID. URL distinguishes
			// those rows; an occurrence disambiguates the occasional exact duplicate.
			let parts = [app.id ?? "", app.downloadURL?.absoluteString ?? app.currentDownloadUrl?.absoluteString ?? app.name ?? ""]
			let identity = parts.map { "\($0.utf8.count):\($0)" }.joined()
			let occurrence = occurrences[identity, default: 0]
			occurrences[identity] = occurrence + 1
			let id = SourceAppRowID(source: context.sourceObjectURI, identity: identity, occurrence: occurrence)
			let contentRevision = contentFingerprint(app, context: context)
			let first = app.name?.trimmingCharacters(in: .whitespacesAndNewlines).first?.uppercased() ?? "#"
			let letter = first.unicodeScalars.contains { (65...90).contains($0.value) } ? first : "#"
			rows.append(SourceAppRow(id: id, sourceObjectURI: context.sourceObjectURI, sourceURL: context.sourceURL,
				source: context.repository, app: app, contentRevision: contentRevision, name: app.name ?? "",
				bundleID: app.id ?? "", date: app.currentDate?.date, letter: letter))
		}
		projections[context.sourceObjectURI] = Projection(key: key, rows: rows)
		if projections.count > 16, let victim = projections.keys.first(where: { $0 != context.sourceObjectURI }) {
			projections[victim] = nil
		}
		return rows
	}

	private func contentFingerprint(_ app: ASRepository.App, context: SourceAppCatalogContext) -> Int {
		var hash = Hasher()
		// Compare semantic dates, not their original JSON representation or decoder UUIDs.
		// A timestamp restored from disk must match the same date received as an ISO string.
		hash.combine(app.id); hash.combine(app.name); hash.combine(app.subtitle)
		hash.combine(app.description); hash.combine(app.developer); hash.combine(app.version)
		hash.combine(app.versionDate?.date); hash.combine(app.date?.date); hash.combine(app.versionDescription)
		hash.combine(app.downloadURL); hash.combine(app.localizedDescription); hash.combine(app.iconURL)
		hash.combine(app.tintColor); hash.combine(app.size); hash.combine(app.category); hash.combine(app.beta)
		hash.combine(app.permissions); hash.combine(app.appPermissions); hash.combine(app.screenshots)
		hash.combine(app.screenshotURLs); hash.combine(app.marketplaceID)
		hash.combine(app.versions?.count)
		for version in app.versions ?? [] {
			hash.combine(version.version); hash.combine(version.build); hash.combine(version.date?.date)
			hash.combine(version.localizedDescription); hash.combine(version.downloadURL)
			hash.combine(version.size); hash.combine(version.minOSVersion)
		}
		hash.combine(context.sourceURL); hash.combine(context.repository.id)
		hash.combine(context.repository.name); hash.combine(context.repository.currentIconURL)
		return hash.finalize()
	}

	private func makeOrder(rows: [SourceAppRow], key: Key) -> Order {
		let indices = rows.indices.sorted { left, right in
			let l = rows[left], r = rows[right]
			if key.sort == "latest" {
				switch (l.date, r.date) {
				case let (a?, b?): return key.ascending ? a < b : a > b
				case (.some, nil): return true
				case (nil, .some): return false
				case (nil, nil): return l.name < r.name
				}
			}
			let comparison = l.name.localizedCaseInsensitiveCompare(r.name)
			if comparison == .orderedSame { return key.ascending ? l.bundleID < r.bundleID : l.bundleID > r.bundleID }
			return key.ascending ? comparison == .orderedAscending : comparison == .orderedDescending
		}
		var grouped: [String: [Int]] = [:]
		var days: [String: Date] = [:]
		var dayTitles: [Date: String] = [:]
		let calendar = Calendar.current
		let formatter = DateFormatter()
		formatter.locale = Locale.current
		formatter.dateFormat = "MMMM d, yyyy"
		for index in indices {
			let title: String
			if key.sort == "latest", let date = rows[index].date {
				let day = calendar.startOfDay(for: date)
				title = dayTitles[day] ?? formatter.string(from: day)
				dayTitles[day] = title
				days[title] = day
			} else {
				title = key.sort == "latest" ? key.unknownDate : rows[index].letter
			}
			grouped[title, default: []].append(index)
		}
		var titles: [String]
		if key.sort == "latest" {
			titles = days.keys.sorted { key.ascending ? days[$0]! < days[$1]! : days[$0]! > days[$1]! }
			if grouped[key.unknownDate] != nil { titles.append(key.unknownDate) }
		} else {
			titles = grouped.keys.sorted {
				if $0 == "#" { return false }
				if $1 == "#" { return true }
				return key.ascending ? $0 < $1 : $0 > $1
			}
		}
		return Order(key: key, sections: titles.map { .init(title: $0, indices: grouped[$0]!) })
	}

	private func cacheFile(_ key: Key) -> URL? {
		let encoder = JSONEncoder()
		encoder.outputFormatting = .sortedKeys
		guard let bytes = try? encoder.encode(key) else { return nil }
		let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
		return cacheDirectory?.appendingPathComponent(digest + ".plist")
	}
	private func loadOrder(key: Key, count: Int) -> Order? {
		guard let file = cacheFile(key), let data = try? Data(contentsOf: file),
		      let order = try? PropertyListDecoder().decode(Order.self, from: data), order.key == key else { return nil }
		let indices = order.sections.flatMap(\.indices)
		guard Set(order.sections.map(\.title)).count == order.sections.count,
		      order.sections.allSatisfy({ !$0.indices.isEmpty }),
		      indices.count == count, Set(indices).count == count,
		      indices.allSatisfy({ (0..<count).contains($0) }) else { return nil }
		return order
	}
	private func trimDiskIndexes() {
		guard let cacheDirectory,
		      let files = try? FileManager.default.contentsOfDirectory(at: cacheDirectory,
			includingPropertiesForKeys: [.contentModificationDateKey]), files.count > 64 else { return }
		let oldest = files.sorted {
			let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
			let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
			return left < right
		}
		for file in oldest.prefix(files.count - 64) { try? FileManager.default.removeItem(at: file) }
	}

	private func persist(_ order: Order) {
		guard let cacheDirectory, let file = cacheFile(order.key) else { return }
		do {
			try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
			let encoder = PropertyListEncoder()
			encoder.outputFormat = .binary
			try encoder.encode(order).write(to: file, options: .atomic)
			trimDiskIndexes()
		} catch { /* Disk indexes are optional; in-memory preparation remains usable. */ }
	}
}
