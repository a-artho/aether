import SwiftUI
import AltSourceKit
import UIKit
import NimbleViews

/// Small, already-matched update lists render directly; icons load independently.
struct InstalledAppUpdatesView: View {
	@AppStorage("Aether.rowHorizontalInset") private var horizontalInset: RowHorizontalInset = .standard
	@AppStorage("Aether.rowSeparators") private var rowSeparators: AppRowSeparatorStyle = .standard
	@Environment(\.nbStickySectionHeaders) private var stickySectionHeaders
	let contexts: [SourceAppCatalogContext]
	@State private var selectedUpdate: SelectedUpdate?
	@StateObject private var groupedUpdates: GroupedUpdates

	init(contexts: [SourceAppCatalogContext]) {
		self.contexts = contexts
		_groupedUpdates = StateObject(wrappedValue: GroupedUpdates(contexts: contexts))
	}

	private struct SelectedUpdate {
		let sourceURL: URL?
		let repository: ASRepository
		let app: ASRepository.App
	}

	private struct UpdateRow: Identifiable {
		let id: SourceAppRowID
		let context: SourceAppCatalogContext
		let app: ASRepository.App
	}

	private struct UpdateGroup: Identifiable {
		let id: String
		let title: String
		let rows: [UpdateRow]
	}

	@MainActor
	private final class GroupedUpdates: ObservableObject {
		@Published private(set) var groups: [UpdateGroup]
		private var signature: [String]

		init(contexts: [SourceAppCatalogContext]) {
			signature = Self.signature(for: contexts)
			groups = InstalledAppUpdatesView.makeGroups(contexts)
		}

		func update(_ contexts: [SourceAppCatalogContext]) {
			let next = Self.signature(for: contexts)
			guard signature != next else { return }
			signature = next
			groups = InstalledAppUpdatesView.makeGroups(contexts)
		}

		private static func signature(for contexts: [SourceAppCatalogContext]) -> [String] {
			contexts.flatMap { [$0.sourceObjectURI, $0.sourceURL?.absoluteString ?? "", $0.revision] }
				+ [Locale.current.identifier, TimeZone.current.identifier,
					String(Calendar.current.startOfDay(for: Date()).timeIntervalSinceReferenceDate)]
		}
	}

	private static func makeGroups(_ contexts: [SourceAppCatalogContext]) -> [UpdateGroup] {
		var rows: [UpdateRow] = []
		for context in contexts {
			var occurrences: [String: Int] = [:]
			var metadata = context.repository
			metadata.apps = []
			metadata.news = nil
			let rowContext = SourceAppCatalogContext(sourceObjectURI: context.sourceObjectURI,
				sourceURL: context.sourceURL, repository: metadata, revision: context.revision)
			for app in context.repository.apps {
				let parts = [app.id ?? "", app.downloadURL?.absoluteString ?? app.currentDownloadUrl?.absoluteString ?? app.name ?? ""]
				let identity = parts.map { "\($0.utf8.count):\($0)" }.joined()
				let occurrence = occurrences[identity, default: 0]
				occurrences[identity] = occurrence + 1
				rows.append(UpdateRow(id: SourceAppRowID(source: context.sourceObjectURI,
					identity: identity, occurrence: occurrence), context: rowContext, app: app))
			}
		}
		rows.sort {
			switch ($0.app.currentDate?.date, $1.app.currentDate?.date) {
			case let (left?, right?): return left > right
			case (.some, nil): return true
			case (nil, .some): return false
			case (nil, nil): return ($0.app.name ?? "") < ($1.app.name ?? "")
			}
		}
		let calendar = Calendar.current
		let formatter = DateFormatter()
		formatter.locale = Locale.current
		formatter.dateFormat = "MMM d, yyyy"
		var result: [UpdateGroup] = []
		var grouped: [String: [UpdateRow]] = [:]
		var ordered: [(String, Date?)] = []
		for row in rows {
			let day = (row.app.currentDate?.date).map { calendar.startOfDay(for: $0) }
			let key = day.map { formatter.string(from: $0) } ?? String.localized("Unknown Date")
			if grouped[key] == nil { ordered.append((key, day)) }
			grouped[key, default: []].append(row)
		}
		for (key, day) in ordered {
			let section = PreparedSourceAppList.Section(title: key, rows: [], date: day)
			result.append(UpdateGroup(id: key,
				title: section.displayTitle(today: .localized("Today"), yesterday: .localized("Yesterday")),
				rows: grouped[key] ?? []))
		}
		return result
	}

	var body: some View {
		let groups = groupedUpdates.groups
		List {
			ForEach(groups) { group in
				updateGroupSection(group)
			}
		}
		.listStyle(.plain)
		.aetherAmbientScrollBackground()
		.onChange(of: contexts) { _, next in groupedUpdates.update(next) }
		.onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
			groupedUpdates.update(contexts)
		}
		.onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
			groupedUpdates.update(contexts)
		}
		.onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
			groupedUpdates.update(contexts)
		}
		.overlay {
			if groups.isEmpty {
				TabPlaceholderView(title: .localized("No Updates Available"),
					description: .localized("No newer versions were found in your added sources."), systemImage: "arrow.triangle.2.circlepath")
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.navigationTitle(String.localized("Newer Versions"))
		.navigationBarTitleDisplayMode(.inline)
		.navigationDestination(isPresented: Binding(
			get: { selectedUpdate != nil }, set: { if !$0 { selectedUpdate = nil } }
		)) {
			if let update = selectedUpdate {
				SourceAppsDetailView(sourceURL: update.sourceURL, source: update.repository, app: update.app)
			}
		}
	}

	@ViewBuilder
	private func updateGroupSection(_ group: UpdateGroup) -> some View {
		if stickySectionHeaders {
			Section {
				updateRows(group)
			} header: {
				SourceAppDateChip(title: group.title)
					.textCase(nil)
			}
			.listSectionSeparator(.hidden)
		} else {
			Section {
				SourceAppDateChip(title: group.title)
					.listRowInsets(EdgeInsets())
					.listRowSeparator(.hidden)
					.listRowBackground(Color.clear)
					.accessibilityAddTraits(.isHeader)
				updateRows(group)
			}
			.listSectionSeparator(.hidden)
		}
	}

	@ViewBuilder
	private func updateRows(_ group: UpdateGroup) -> some View {
		ForEach(group.rows) { row in
			SourceAppsCellView(sourceURL: row.context.sourceURL, source: row.context.repository,
				app: row.app, showSourceBadge: true, onSelect: {
					selectedUpdate = SelectedUpdate(sourceURL: row.context.sourceURL,
						repository: row.context.repository, app: row.app)
				})
				.listRowBackground(Color.clear)
				.listRowInsets(.horizontal, horizontalInset.points)
				.listRowSeparator(rowSeparators.listVisibility)
				.listRowSeparatorTint(rowSeparators.listTint)
		}
	}
}
