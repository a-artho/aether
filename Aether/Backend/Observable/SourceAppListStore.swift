import Foundation
import CryptoKit
import AltSourceKit
import UIKit
import os

private let sourceAppListSignpostLog = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "Aether", category: "SourceAppList")

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
	let searchFields: [String]
}

struct PreparedSourceAppList: Sendable {
	struct Section: Sendable {
		let title: String
		let rows: [SourceAppRowID]
		let date: Date?

		func displayTitle(today: String, yesterday: String, calendar: Calendar = .current, now: Date = Date()) -> String {
			guard let date else { return title }
			if calendar.isDate(date, inSameDayAs: now) { return today }
			if let previousDay = calendar.date(byAdding: .day, value: -1, to: now),
				calendar.isDate(date, inSameDayAs: previousDay) { return yesterday }
			return title
		}
	}
	let sections: [Section]
	let rows: [SourceAppRowID: SourceAppRow]
	var catalogRevisions: [String] = []

	/// Content changes exclude random decoder UUIDs. UIKit keeps unchanged cells alive.
	func changedRows(comparedTo previous: Self?) -> [SourceAppRowID] {
		guard let previous else { return [] }
		if !catalogRevisions.isEmpty, catalogRevisions == previous.catalogRevisions { return [] }
		return rows.compactMap { id, row in
			guard let old = previous.rows[id], old.contentRevision != row.contentRevision else { return nil }
			return id
		}
	}
}

struct SourceAppPresentation: Sendable {
	let list: PreparedSourceAppList
	let snapshot: NSDiffableDataSourceSnapshot<String, SourceAppRowID>
	let changedRows: [SourceAppRowID]
}

struct SourceAppPresentationResult: Sendable {
	let current: SourceAppPresentation
	let base: SourceAppPresentation?
}

/// Reuses catalog projections and sorted section indexes across navigation and app launches.
/// Filtering, sorting, hashing, grouping and disk access all run on this actor, away from UI work.
actor SourceAppListStore {
	static let shared = SourceAppListStore()
	private struct Key: Hashable, Codable, Sendable {
		let sources: [String]
		let sort: String
		let ascending: Bool
		let locale: String
		let timeZone: String
		let unknownDate: String
		var formatVersion = 3
	}
	private struct Order: Codable, Sendable {
		struct Section: Codable, Sendable { let title: String; let indices: [Int]; let date: Date? }
		let key: Key
		let sections: [Section]
	}
	private struct Projection {
		let key: [String]
		let rows: [SourceAppRow]
	}
	private let cacheDirectory: URL?
	private let diskWriter = DispatchQueue(label: "Aether.SourceListIndexes", qos: .utility)
	private var projections: [String: Projection] = [:]
	private var removedSources = Set<String>()
	private var prepared: [Key: PreparedSourceAppList] = [:]

	init(cacheDirectory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
		.first?.appendingPathComponent("SourceListIndexes", isDirectory: true)) {
		self.cacheDirectory = cacheDirectory
	}

	func clearCache() {
		prepared.removeAll()
		projections.removeAll()
		if let cacheDirectory {
			// Drain older writes before deleting so they cannot restore a reset index.
			diskWriter.sync { try? FileManager.default.removeItem(at: cacheDirectory) }
		}
	}

	func list(
		contexts: [SourceAppCatalogContext], sort: String, ascending: Bool,
		query: String, unknownDate: String
	) throws -> PreparedSourceAppList {
		try Task.checkCancellation()
		let contexts = contexts.filter { !removedSources.contains($0.sourceObjectURI) }
		let sourceKeys = contexts.flatMap { [$0.sourceObjectURI, $0.sourceURL?.absoluteString ?? "", $0.revision] }
		let key = Key(sources: sourceKeys, sort: sort, ascending: ascending,
			locale: Locale.current.identifier, timeZone: TimeZone.current.identifier, unknownDate: unknownDate)
		let base: PreparedSourceAppList
		if let cached = prepared[key] {
			os_signpost(.event, log: sourceAppListSignpostLog, name: "Prepared list cache hit", "%{public}d", cached.rows.count)
			base = cached
		} else {
			os_signpost(.event, log: sourceAppListSignpostLog, name: "Prepared list cache miss", "%{public}d", contexts.reduce(0) { $0 + $1.repository.apps.count })
			let rows = try contexts.flatMap { try projection(for: $0) }
			let storedOrder = loadOrder(key: key, count: rows.count)
			os_signpost(.event, log: sourceAppListSignpostLog,
				name: storedOrder == nil ? "Sort index cache miss" : "Sort index cache hit", "%{public}d", rows.count)
			let order = storedOrder ?? makeOrder(rows: rows, key: key)
			try Task.checkCancellation()
			base = PreparedSourceAppList(
				sections: order.sections.map { .init(title: $0.title, rows: $0.indices.map { rows[$0].id }, date: $0.date) },
				rows: Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) }),
				catalogRevisions: sourceKeys
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
				if row.searchFields.enumerated().contains(where: { index, field in
					index == 0
						? field.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: locale) != nil
						: field.localizedCaseInsensitiveContains(query)
				}) {
					ids.append(id)
					matches[id] = row
				}
			}
			if !ids.isEmpty { sections.append(.init(title: section.title, rows: ids, date: section.date)) }
		}
		return PreparedSourceAppList(sections: sections, rows: matches, catalogRevisions: base.catalogRevisions)
	}

	/// Prepare the selected full-list ordering before its repository is published as ready.
	/// Existing projections, ordering indexes, and bounded prepared-list caches are reused.
	func warm(
		contexts: [SourceAppCatalogContext], sort: String, ascending: Bool, unknownDate: String
	) throws {
		let signpostID = OSSignpostID(log: sourceAppListSignpostLog)
		os_signpost(.begin, log: sourceAppListSignpostLog, name: "Warm repository catalog", signpostID: signpostID,
			"sources=%{public}d", contexts.count)
		defer { os_signpost(.end, log: sourceAppListSignpostLog, name: "Warm repository catalog", signpostID: signpostID) }
		_ = try list(contexts: contexts, sort: sort, ascending: ascending, query: "", unknownDate: unknownDate)
	}

	/// Prepare a presentation and its UIKit snapshot off the main actor. When the coordinator
	/// has no valid base ordering (such as after a sort or catalog change during search),
	/// include that unfiltered presentation in the same actor request.
	func presentation(
		contexts: [SourceAppCatalogContext], sort: String, ascending: Bool,
		query: String, unknownDate: String, includeBase: Bool,
		comparedTo previous: PreparedSourceAppList?
	) throws -> SourceAppPresentationResult {
		let signpostID = OSSignpostID(log: sourceAppListSignpostLog)
		os_signpost(.begin, log: sourceAppListSignpostLog, name: "Prepare source app presentation", signpostID: signpostID,
			"queryLength=%{public}d", query.count)
		defer { os_signpost(.end, log: sourceAppListSignpostLog, name: "Prepare source app presentation", signpostID: signpostID) }
		try Task.checkCancellation()
		let baseList = try list(contexts: contexts, sort: sort, ascending: ascending,
			query: "", unknownDate: unknownDate)
		if query.isEmpty {
			let presentation = makePresentation(baseList, comparedTo: previous)
			return SourceAppPresentationResult(current: presentation, base: presentation)
		}
		let currentList = try list(contexts: contexts, sort: sort, ascending: ascending,
			query: query, unknownDate: unknownDate)
		let basePresentation = includeBase ? makePresentation(baseList, comparedTo: nil) : nil
		let currentPresentation = makePresentation(currentList, comparedTo: previous)
		return SourceAppPresentationResult(current: currentPresentation, base: basePresentation)
	}

	private func makePresentation(
		_ list: PreparedSourceAppList, comparedTo previous: PreparedSourceAppList?
	) -> SourceAppPresentation {
		let signpostID = OSSignpostID(log: sourceAppListSignpostLog)
		os_signpost(.begin, log: sourceAppListSignpostLog, name: "Build diffable snapshot", signpostID: signpostID,
			"rows=%{public}d", list.rows.count)
		defer { os_signpost(.end, log: sourceAppListSignpostLog, name: "Build diffable snapshot", signpostID: signpostID) }
		var snapshot = NSDiffableDataSourceSnapshot<String, SourceAppRowID>()
		for section in list.sections {
			snapshot.appendSections([section.title])
			snapshot.appendItems(section.rows, toSection: section.title)
		}
		let changedRows = list.changedRows(comparedTo: previous)
		if !changedRows.isEmpty { snapshot.reconfigureItems(changedRows) }
		return SourceAppPresentation(list: list, snapshot: snapshot, changedRows: changedRows)
	}

	func removeSource(_ source: String) {
		removedSources.insert(source)
		projections[source] = nil
		prepared = prepared.filter { !$0.key.sources.enumerated().contains { $0.offset % 3 == 0 && $0.element == source } }
	}

	func changedRows(in list: PreparedSourceAppList, comparedTo previous: PreparedSourceAppList?) -> [SourceAppRowID] {
		list.changedRows(comparedTo: previous)
	}

	private func projection(for context: SourceAppCatalogContext) throws -> [SourceAppRow] {
		let key = [context.revision, context.sourceURL?.absoluteString ?? ""]
		if let cached = projections[context.sourceObjectURI], cached.key == key {
			os_signpost(.event, log: sourceAppListSignpostLog, name: "Projection cache hit", "%{public}d", cached.rows.count)
			return cached.rows
		}
		os_signpost(.event, log: sourceAppListSignpostLog, name: "Projection cache miss", "%{public}d", context.repository.apps.count)
		var repository = context.repository
		repository.apps = []
		repository.news = nil
		let sourceRevision = sourceFingerprint(context)
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
			let contentRevision = contentFingerprint(app, sourceRevision: sourceRevision)
			let first = app.name?.trimmingCharacters(in: .whitespacesAndNewlines).first?.uppercased() ?? "#"
			let letter = first.unicodeScalars.contains { (65...90).contains($0.value) } ? first : "#"
			rows.append(SourceAppRow(id: id, sourceObjectURI: context.sourceObjectURI, sourceURL: context.sourceURL,
				source: repository, app: app, contentRevision: contentRevision, name: app.name ?? "",
				bundleID: app.id ?? "", date: app.currentDate?.date, letter: letter,
				searchFields: [app.id ?? ""] + Array(Set([app.name, app.description, app.subtitle, app.localizedDescription].compactMap { $0 }))))
		}
		projections[context.sourceObjectURI] = Projection(key: key, rows: rows)
		if projections.count > 16, let victim = projections.keys.first(where: { $0 != context.sourceObjectURI }) {
			projections[victim] = nil
		}
		return rows
	}

	private func sourceFingerprint(_ context: SourceAppCatalogContext) -> Int {
		var hash = Hasher()
		hash.combine(context.sourceURL); hash.combine(context.repository.id)
		hash.combine(context.repository.name); hash.combine(context.repository.currentIconURL)
		return hash.finalize()
	}

	private func contentFingerprint(_ app: ASRepository.App, sourceRevision: Int) -> Int {
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
		hash.combine(sourceRevision)
		return hash.finalize()
	}

	private func makeOrder(rows: [SourceAppRow], key: Key) -> Order {
		if key.sort == "default" {
			return Order(key: key, sections: rows.isEmpty ? [] : [
				.init(title: "", indices: Array(rows.indices), date: nil)
			])
		}
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
		formatter.dateFormat = "MMM d, yyyy"
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
		return Order(key: key, sections: titles.map { .init(title: $0, indices: grouped[$0]!, date: days[$0]) })
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
	private nonisolated static func trimDiskIndexes(in directory: URL) {
		guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
			includingPropertiesForKeys: [.contentModificationDateKey]), files.count > 64 else { return }
		// Fetch each file's date once, rather than performing metadata reads inside sorting.
		let dated = files.map { file in
			(file, (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
		}.sorted { $0.1 < $1.1 }
		for (file, _) in dated.prefix(files.count - 64) { try? FileManager.default.removeItem(at: file) }
	}

	private func persist(_ order: Order) {
		guard let directory = cacheDirectory, let file = cacheFile(order.key) else { return }
		// Optional index serialization and disk writes never delay returning the list.
		diskWriter.async {
			do {
				try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
				let encoder = PropertyListEncoder()
				encoder.outputFormat = .binary
				try encoder.encode(order).write(to: file, options: .atomic)
				Self.trimDiskIndexes(in: directory)
			} catch { /* Disk indexes are optional; in-memory preparation remains usable. */ }
		}
	}
}
