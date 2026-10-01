//
//  SourceAppsTableView.swift
//  Aether
//
//  Created by samara on 3.05.2025.
//

import SwiftUI
import AltSourceKit

// MARK: - Representable
struct SourceAppsTableRepresentableView: UIViewRepresentable {
	var sourceContexts: [SourceAppsView.SourceRepositoryContext]
	@Binding var searchText: String
	@Binding var sortOption: SourceAppsView.SortOption
	@Binding var sortAscending: Bool
	var showSourceBadge: Bool = false
	var onSelect: (SourceAppsView.SourceAppRoute) -> Void
	
	func makeUIView(context: Context) -> UITableView {
		let tableView = UITableView(frame: .zero, style: .plain)
		tableView.delegate = context.coordinator
		tableView.dataSource = context.coordinator
		tableView.register(UITableViewCell.self, forCellReuseIdentifier: "AppCell")
		tableView.register(UITableViewHeaderFooterView.self, forHeaderFooterViewReuseIdentifier: "SectionHeader")

		tableView.allowsSelection = true

		tableView.alpha = 0
		
		UIView.transition(with: tableView,  duration: 0.5, options: [.transitionCrossDissolve], animations: {
			tableView.alpha = 1
		}, completion: nil)
		
		return tableView
	}
	
	func updateUIView(_ tableView: UITableView, context: Context) {
		context.coordinator.uiTableView = tableView
		
		let sourcesChanged = context.coordinator.sourceContexts != sourceContexts
		let searchChanged = context.coordinator.searchText != searchText
		let sortOptionChanged = context.coordinator.sortOption != sortOption
		let sortDirectionChanged = context.coordinator.sortAscending != sortAscending
		let badgeChanged = context.coordinator.showSourceBadge != showSourceBadge
		
		context.coordinator.sourceContexts = sourceContexts
		context.coordinator.searchText = searchText
		context.coordinator.sortOption = sortOption
		context.coordinator.sortAscending = sortAscending
		context.coordinator.showSourceBadge = showSourceBadge
		context.coordinator.updateNewsHeader(for: tableView)
		
		if sourcesChanged || searchChanged || sortOptionChanged || sortDirectionChanged || badgeChanged {
			context.coordinator.invalidateCache(debouncingSearch: searchChanged && !sourcesChanged && !sortOptionChanged && !sortDirectionChanged && !badgeChanged)
		}
	}
	
	func makeCoordinator() -> Coordinator {
		Coordinator(
			sourceContexts: sourceContexts,
			searchText: searchText,
			sortOption: sortOption,
			sortAscending: sortAscending,
			showSourceBadge: showSourceBadge,
			onSelect: onSelect
		)
	}
}

// MARK: - Representable Extension: Coordinator
extension SourceAppsTableRepresentableView { class Coordinator: NSObject, UITableViewDataSource, UITableViewDelegate {
	var sourceContexts: [SourceAppsView.SourceRepositoryContext]
	var searchText: String
	var sortOption: SourceAppsView.SortOption
	var sortAscending: Bool
	var showSourceBadge: Bool
	let onSelect: (SourceAppsView.SourceAppRoute) -> Void
	
	private var _groupedAppsByNameFirstLetter: [String: [SourceAppEntry]] = [:]
	private var _groupedAppsByDate: [String: [SourceAppEntry]] = [:]
	private var _sortedSectionTitles: [String] = []
	private let _unknownDateSectionTitle = String.localized("Unknown Date")
	
	private var _cachedSortedApps: [SourceAppEntry]?
	private var _searchReloadWorkItem: DispatchWorkItem?
	private var _newsHeaderController: UIHostingController<SourceNewsView>?
	private var _newsHeaderSignature: String?
	private var _newsHeaderWidth: CGFloat = 0
	weak var uiTableView: UITableView?
	
	private var _allAppsWithSource: [SourceAppEntry] {
		sourceContexts.flatMap { context in
			context.repository.apps.map {
				SourceAppEntry(
					sourceURL: context.sourceURL,
					source: context.repository,
					app: $0
				)
			}
		}
	}
	
	private var _sortedApps: [SourceAppEntry] {
		if let _cachedSortedApps {
			return _cachedSortedApps
		}
		_cachedSortedApps = _calculateSortedApps()
		return _cachedSortedApps ?? []
	}
	
	init(
		sourceContexts: [SourceAppsView.SourceRepositoryContext],
		searchText: String,
		sortOption: SourceAppsView.SortOption,
		sortAscending: Bool,
		showSourceBadge: Bool,
		onSelect: @escaping (SourceAppsView.SourceAppRoute) -> Void
	) {
		self.sourceContexts = sourceContexts
		self.searchText = searchText
		self.sortOption = sortOption
		self.sortAscending = sortAscending
		self.showSourceBadge = showSourceBadge
		self.onSelect = onSelect
		super.init()
		
		if sortOption != .default {
			invalidateCache()
		}
	}
	
	private func _calculateSortedApps() -> [SourceAppEntry] {
		let filtered = _allAppsWithSource.filter {
			searchText.isEmpty ||
			($0.app.id?.range(of: searchText, options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US")) != nil) ||
				($0.app.name?.localizedCaseInsensitiveContains(searchText) ?? false) ||
				($0.app.description?.localizedCaseInsensitiveContains(searchText) ?? false) ||
				($0.app.subtitle?.localizedCaseInsensitiveContains(searchText) ?? false) ||
				($0.app.localizedDescription?.localizedCaseInsensitiveContains(searchText) ?? false)
		}
		
		switch sortOption {
		case .default:
			_groupedAppsByDate = [:]
			_groupedAppsByNameFirstLetter = [:]
			_sortedSectionTitles = []
			return sortAscending ? filtered : filtered.reversed()
		case .date:
			let sorted = filtered.sorted {
				switch ($0.app.currentDate?.date, $1.app.currentDate?.date) {
				case let (d1?, d2?):
					return sortAscending ? d1 < d2 : d1 > d2
				case (.some, nil):
					return true
				case (nil, .some):
					return false
				case (nil, nil):
					return ($0.app.name ?? "") < ($1.app.name ?? "")
				}
			}
			
			let formatter = DateFormatter()
			formatter.dateFormat = "MMMM d, yyyy"

			var grouped: [String: [SourceAppEntry]] = [:]
			var datesByTitle: [String: Date] = [:]
			for entry in sorted {
				guard let date = entry.app.currentDate?.date.stripTime() else {
					grouped[_unknownDateSectionTitle, default: []].append(entry)
					continue
				}
				let title = formatter.string(from: date)
				datesByTitle[title] = date
				grouped[title, default: []].append(entry)
			}

			var sortedTitles = datesByTitle.keys.sorted {
				guard let left = datesByTitle[$0], let right = datesByTitle[$1] else {
					return false
				}
				return sortAscending ? left < right : left > right
			}
			if grouped[_unknownDateSectionTitle] != nil {
				sortedTitles.append(_unknownDateSectionTitle)
			}

			_groupedAppsByDate = grouped
			_sortedSectionTitles = sortedTitles
			return sorted
		case .name:
			let sorted = filtered.sorted {
				let n1 = $0.app.name ?? ""
				let n2 = $1.app.name ?? ""
				let comparison = n1.localizedCaseInsensitiveCompare(n2)
				if comparison == .orderedSame {
					let id1 = $0.app.id ?? ""
					let id2 = $1.app.id ?? ""
					return sortAscending ? id1 < id2 : id1 > id2
				}
				return sortAscending
					? comparison == .orderedAscending
					: comparison == .orderedDescending
			}
			_groupedAppsByNameFirstLetter = Dictionary(grouping: sorted) {
				let first = $0.app.name?.trimmingCharacters(in: .whitespacesAndNewlines).first?.uppercased() ?? "#"
				return first.range(of: "[A-Z]", options: .regularExpression) != nil ? first : "#"
			}
			_sortedSectionTitles = _groupedAppsByNameFirstLetter.keys.sorted(by: {
				if $0 == "#" { return false }
				if $1 == "#" { return true }
				return sortAscending ? $0 < $1 : $0 > $1
			})
			return sorted
		}
	}
	
	func invalidateCache(debouncingSearch: Bool = false) {
		_cachedSortedApps = nil
		_searchReloadWorkItem?.cancel()

		let reload = { [weak self] in
			guard let self else { return }
			self._cachedSortedApps = self._calculateSortedApps()
			self.uiTableView?.reloadData()
		}

		guard debouncingSearch else {
			reload()
			return
		}

		let workItem = DispatchWorkItem(block: reload)
		_searchReloadWorkItem = workItem
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
	}

	func updateNewsHeader(for tableView: UITableView) {
		guard
			sourceContexts.count == 1,
			let news = sourceContexts[0].repository.news,
			!news.isEmpty
		else {
			_newsHeaderController = nil
			_newsHeaderSignature = nil
			_newsHeaderWidth = 0
			tableView.tableHeaderView = nil
			return
		}

		let width = tableView.bounds.width
		guard width > 0 else { return }
		let signature = news.map { "\($0.id)|\($0.title)|\($0.caption)|\(String(describing: $0.date))" }
			.joined(separator: "\n")

		let headerController: UIHostingController<SourceNewsView>
		if let _newsHeaderController {
			headerController = _newsHeaderController
			if _newsHeaderSignature != signature {
				headerController.rootView = SourceNewsView(news: news)
			}
		} else {
			headerController = UIHostingController(rootView: SourceNewsView(news: news))
			headerController.view.backgroundColor = .clear
			headerController.view.translatesAutoresizingMaskIntoConstraints = true
			_newsHeaderController = headerController
		}

		_newsHeaderSignature = signature
		headerController.view.frame = CGRect(x: 0, y: 0, width: width, height: 1)
		let fittingSize = headerController.sizeThatFits(in:
			CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
		)
		let height = max(0, ceil(fittingSize.height))
		let needsReplacement = tableView.tableHeaderView !== headerController.view ||
			_newsHeaderWidth != width ||
			headerController.view.bounds.height != height
		guard needsReplacement else { return }

		_newsHeaderWidth = width
		headerController.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
		tableView.tableHeaderView = headerController.view
	}
	
	// MARK: TableView
	
	func numberOfSections(in tableView: UITableView) -> Int {
		switch sortOption {
		case .default: 1
		case .name, .date: _sortedSectionTitles.count
		}
	}
	
	func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
		switch sortOption {
		case .default: _sortedApps.count
		case .name: _groupedAppsByNameFirstLetter[_sortedSectionTitles[section]]?.count ?? 0
		case .date: _groupedAppsByDate[_sortedSectionTitles[section]]?.count ?? 0
		}
	}
	
	func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
		let cell = tableView.dequeueReusableCell(withIdentifier: "AppCell", for: indexPath)
		let entry: SourceAppEntry
		switch sortOption {
		case .default: entry = _sortedApps[indexPath.row]
		case .name: entry = _groupedAppsByNameFirstLetter[_sortedSectionTitles[indexPath.section]]?[indexPath.row] ?? _sortedApps[indexPath.row]
		case .date: entry = _groupedAppsByDate[_sortedSectionTitles[indexPath.section]]?[indexPath.row] ?? _sortedApps[indexPath.row]
		}

		cell.contentConfiguration = UIHostingConfiguration {
			SourceAppsCellView(
				sourceURL: entry.sourceURL,
				source: entry.source,
				app: entry.app,
				showSourceBadge: showSourceBadge
			)
			.tint(Color(hex: UserDefaults.standard.string(forKey: "Aether.userTintColor") ?? "#848ef9"))
		}
		return cell
	}
	
	func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
		tableView.deselectRow(at: indexPath, animated: true)

		let entry: SourceAppEntry
		switch sortOption {
		case .default: entry = _sortedApps[indexPath.row]
		case .name: entry = _groupedAppsByNameFirstLetter[_sortedSectionTitles[indexPath.section]]?[indexPath.row] ?? _sortedApps[indexPath.row]
		case .date: entry = _groupedAppsByDate[_sortedSectionTitles[indexPath.section]]?[indexPath.row] ?? _sortedApps[indexPath.row]
		}

		onSelect(SourceAppsView.SourceAppRoute(sourceURL: entry.sourceURL, source: entry.source, app: entry.app))
	}
	
	func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
		let headerView = tableView.dequeueReusableHeaderFooterView(withIdentifier: "SectionHeader")
		let title: String
		
		switch sortOption {
		case .default: title = .localized("%lld Apps", arguments: _sortedApps.count)
		case .name, .date: title = _sortedSectionTitles[section]
		}
		
		headerView?.contentConfiguration = UIHostingConfiguration {
			HStack {
				Text(verbatim: title)
				Spacer()
			}
			.font(.headline)
			.padding(.vertical, 2)
		}
		
		return headerView
	}
	
	func sectionIndexTitles(for tableView: UITableView) -> [String]? {
		sortOption == .name ? _sortedSectionTitles : nil
	}
	
	func tableView(_ tableView: UITableView, sectionForSectionIndexTitle title: String, at index: Int) -> Int {
		_sortedSectionTitles.firstIndex(of: title) ?? 0
	}
	
	func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
		let entry: SourceAppEntry
		switch sortOption {
		case .default: entry = _sortedApps[indexPath.row]
		case .name: entry = _groupedAppsByNameFirstLetter[_sortedSectionTitles[indexPath.section]]?[indexPath.row] ?? _sortedApps[indexPath.row]
		case .date: entry = _groupedAppsByDate[_sortedSectionTitles[indexPath.section]]?[indexPath.row] ?? _sortedApps[indexPath.row]
		}
		
		return UIContextMenuConfiguration(
			identifier: nil,
			previewProvider: nil
		) { _ in
			let versionsMenu = UIMenu(
				title: .localized("Copy Download URLs"),
				image: UIImage(systemName: "list.bullet"),
				children: self._contextActions(for: entry.app, with: { _, url in
					UIPasteboard.general.string = url?.absoluteString
				}, image: UIImage(systemName: "doc.on.clipboard"))
			)
			
			let downloadsMenu = UIMenu(
				title: .localized("Previous Versions"),
				image: UIImage(systemName: "square.and.arrow.down.on.square"),
				children: self._contextActions(for: entry.app, with: { version, url in
					if let url {
						_ = DownloadManager.shared.startDownload(
							from: url,
							id: entry.app.currentUniqueId,
							sourceProvenance: SourceAppProvenance(
								sourceURL: entry.sourceURL,
								repository: entry.source,
								app: entry.app,
								version: version
							)
						)
					}
				}, image: UIImage(systemName: "arrow.down"))
			)
			
			return UIMenu(children: [downloadsMenu, versionsMenu])
		}
	}
	
	// MARK: Actions
	
	private func _contextActions(
		for app: ASRepository.App,
		with action: @escaping (ASRepository.App.Version?, URL?) -> Void,
		image: UIImage?
	) -> [UIAction] {
		if let versions = app.versions, !versions.isEmpty {
			return versions.map { version in
				UIAction(
					title: version.version,
					image: image
				) { _ in
					action(version, version.downloadURL)
				}
			}
		} else {
			return [
				UIAction(
					title: app.currentVersion ?? "",
					image: image
				) { _ in
					action(nil, app.currentDownloadUrl)
				}
			]
		}
	}
}}

private struct SourceAppEntry {
	let sourceURL: URL?
	let source: ASRepository
	let app: ASRepository.App
}
