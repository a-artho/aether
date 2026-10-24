//
//  SourceAppsTableView.swift
//  Aether
//
//  Created by samara on 3.05.2025.
//

import SwiftUI
import AltSourceKit
import UIKit
import NimbleViews

private final class SourceAppTableCell: UITableViewCell {
	// These rows have no responder editing actions. Their copy/download menus are
	// supplied by the table delegate. UIKit's default implementation searches its
	// tentative-cell map for each accessibility attribute, quadratically on large lists.
	override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool { false }
}

/// Uses the same hosting margins, typography and native section layout as real rows.
private struct SourceAppsSkeletonRow: View {
	@AppStorage("Aether.rowIconSize") private var rowIconSize: RowIconSize = .standard
	@AppStorage("Aether.storeCellAppearance") private var appearance = 0
	var showsDownloadButton: Bool
	private func skeletonBar(width: CGFloat, height: CGFloat) -> some View {
		RoundedRectangle(cornerRadius: 3).fill(Color(uiColor: .tertiarySystemFill))
			.frame(maxWidth: width, alignment: .leading).frame(height: height)
	}
	var body: some View {
		VStack {
			HStack(spacing: NBRowMetrics.contentSpacing) {
				AppIconSkeleton(size: rowIconSize.points, isLoading: false)
				VStack(alignment: .leading, spacing: NBRowMetrics.lineSpacing) {
					Text("Application name").nbRowTitle().hidden()
						.overlay(alignment: .leading) { skeletonBar(width: 150, height: 12) }
					VStack(alignment: .leading, spacing: NBRowMetrics.lineSpacing) {
						Text("1.0.0").nbRowSubtitle().hidden()
							.overlay(alignment: .leading) { skeletonBar(width: 45, height: 10) }
						if appearance == 0 { Text("Application description").font(.footnote).hidden()
							.overlay(alignment: .leading) { skeletonBar(width: 175, height: 10) } }
					}
				}
				.padding(.vertical, NBRowMetrics.textVerticalPadding)
				.frame(maxWidth: .infinity, alignment: .leading)
				.foregroundStyle(.tertiary)
				if showsDownloadButton {
					RoundedRectangle(cornerRadius: 4)
						.fill(Color(uiColor: .tertiarySystemFill))
						.frame(width: 22, height: 18).frame(width: 44, height: 44)
				}
			}
			if appearance != 0 {
				Text("Application description\nAdditional application details")
					.nbRowSubtitle().frame(maxWidth: .infinity, alignment: .leading)
					.padding(.top, 2).hidden()
					.overlay(alignment: .leading) {
						VStack(alignment: .leading, spacing: 7) {
							skeletonBar(width: 230, height: 10)
							skeletonBar(width: 180, height: 10)
						}
					}
			}
		}
		.modifier(SourceAppsSkeletonPulse())
		.accessibilityHidden(true)
	}
}

/// A single pulse for the complete placeholder, active only while it is visible.
private struct SourceAppsSkeletonPulse: ViewModifier {
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@Environment(\.scenePhase) private var scenePhase
	@State private var isVisible = false

	func body(content: Content) -> some View {
		Group {
			if isVisible && scenePhase == .active && !reduceMotion {
				content.phaseAnimator([false, true]) { view, dimmed in
					view.opacity(dimmed ? 0.5 : 1)
				} animation: { _ in .easeInOut(duration: 1) }
			} else { content }
		}
		.onAppear { isVisible = true }
		.onDisappear { isVisible = false }
	}
}

// MARK: - Representable
struct SourceAppsTableRepresentableView: UIViewRepresentable {
	@AppStorage("Aether.rowHorizontalInset") private var horizontalInset: RowHorizontalInset = .standard
	@AppStorage("Aether.showRepoDownloadButtons") private var showsDownloadButtons = true
	@AppStorage("Aether.userTintColor") private var themeHex = "#848ef9"
	var sourceContexts: [SourceAppsView.SourceRepositoryContext]
	var isCatalogLoading = false
	@Binding var searchText: String
	@Binding var sortOption: SourceAppsView.SortOption
	var sortAscending: Bool
	var showSourceBadge: Bool = false
	var listStore: SourceAppListStore = .shared
	var onSelect: (SourceAppsView.SourceAppSelection) -> Void
	
	func makeUIView(context: Context) -> UITableView {
		let tableView = UITableView(frame: .zero, style: .plain)
		// Native plain-table headers remain pinned until the next section replaces them.
		tableView.backgroundColor = .systemBackground
		tableView.sectionFooterHeight = .leastNormalMagnitude
		tableView.estimatedSectionFooterHeight = .leastNormalMagnitude
		tableView.delegate = context.coordinator
		tableView.register(SourceAppTableCell.self, forCellReuseIdentifier: "AppCell")
		tableView.register(UITableViewHeaderFooterView.self, forHeaderFooterViewReuseIdentifier: "SectionHeader")

		// Explicit estimates let large catalogs lay out visible rows/headers first.
		tableView.estimatedRowHeight = 80
		tableView.estimatedSectionHeaderHeight = 32
		tableView.rowHeight = UITableView.automaticDimension
		tableView.sectionHeaderHeight = UITableView.automaticDimension
		tableView.allowsSelection = true
		tableView.keyboardDismissMode = .onDrag
		context.coordinator.horizontalInset = horizontalInset
		context.coordinator.attach(to: tableView)

		return tableView
	}
	
	func updateUIView(_ tableView: UITableView, context: Context) {
		context.coordinator.uiTableView = tableView
		context.coordinator.onSelect = onSelect
		
		let sourcesChanged = context.coordinator.sourceContexts != sourceContexts
		let loadingChanged = context.coordinator.isCatalogLoading != isCatalogLoading
		let searchChanged = context.coordinator.searchText != searchText
		let sortOptionChanged = context.coordinator.sortOption != sortOption
		let sortDirectionChanged = context.coordinator.sortAscending != sortAscending
		let badgeChanged = context.coordinator.showSourceBadge != showSourceBadge
		let accessoryChanged = context.coordinator.showsDownloadButtons != showsDownloadButtons || context.coordinator.themeHex != themeHex || context.coordinator.horizontalInset != horizontalInset
		
		context.coordinator.sourceContexts = sourceContexts
		context.coordinator.isCatalogLoading = isCatalogLoading
		context.coordinator.searchText = searchText
		context.coordinator.sortOption = sortOption
		context.coordinator.sortAscending = sortAscending
		context.coordinator.showSourceBadge = showSourceBadge
		context.coordinator.showsDownloadButtons = showsDownloadButtons
		context.coordinator.themeHex = themeHex
		context.coordinator.horizontalInset = horizontalInset
		context.coordinator.updateNewsHeader(for: tableView)
		if accessoryChanged { context.coordinator.refreshVisibleAccessories() }
		
		if sourcesChanged || loadingChanged || searchChanged || sortOptionChanged || sortDirectionChanged || badgeChanged {
			context.coordinator.prepareList(
				debouncingSearch: searchChanged && !sourcesChanged && !sortOptionChanged && !sortDirectionChanged && !badgeChanged,
				preserveScroll: sourcesChanged && !searchChanged && !sortOptionChanged && !sortDirectionChanged,
				refreshVisibleRows: badgeChanged,
				fadeSearchResults: searchChanged
			)
		}
	}
	
	func makeCoordinator() -> Coordinator {
		Coordinator(
			sourceContexts: sourceContexts,
			isCatalogLoading: isCatalogLoading,
			searchText: searchText,
			sortOption: sortOption,
			sortAscending: sortAscending,
			showSourceBadge: showSourceBadge,
			showsDownloadButtons: showsDownloadButtons,
			listStore: listStore,
			onSelect: onSelect
		)
	}
}

// MARK: - Representable Extension: Coordinator
extension SourceAppsTableRepresentableView { @MainActor class Coordinator: NSObject, UITableViewDelegate {
	func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
		// The search field lives in the navigation bar, outside this scroll view's controller.
		scrollView.window?.endEditing(true)
	}
	var sourceContexts: [SourceAppsView.SourceRepositoryContext]
	var isCatalogLoading: Bool
	var searchText: String
	var sortOption: SourceAppsView.SortOption
	var sortAscending: Bool
	var showSourceBadge: Bool
	var showsDownloadButtons: Bool
	var themeHex = "#848ef9"
	var horizontalInset: RowHorizontalInset = .standard
	let listStore: SourceAppListStore
	var onSelect: (SourceAppsView.SourceAppSelection) -> Void
	
	private var _dataSource: DataSource?
	private var _displayed: PreparedSourceAppList?
	private var _previousDisplay: PreparedSourceAppList?
	private var _prepareTask: Task<Void, Never>?
	private var _generation = 0
	private var _hasAppliedList = false
	private var _loadingDeadline: ContinuousClock.Instant?
	private static let loadingSection = "aether-loading"
	private var _loadingSections: [PreparedSourceAppList.Section] = []
	private var _newsHeaderController: UIHostingController<SourceNewsView>?
	private var _newsHeaderSignature: String?
	private var _newsHeaderWidth: CGFloat = 0
	private var _dateObservers: [NSObjectProtocol] = []
	private var _dateContextSignature = Locale.current.identifier + "|" + TimeZone.current.identifier
	weak var uiTableView: UITableView?

	private class DataSource: UITableViewDiffableDataSource<String, SourceAppRowID> {
		var showsAlphabeticalIndex = false
		override func sectionIndexTitles(for tableView: UITableView) -> [String]? {
			showsAlphabeticalIndex ? snapshot().sectionIdentifiers : nil
		}
		override func tableView(_ tableView: UITableView, sectionForSectionIndexTitle title: String, at index: Int) -> Int {
			snapshot().sectionIdentifiers.firstIndex(of: title) ?? 0
		}
	}

	init(
		sourceContexts: [SourceAppsView.SourceRepositoryContext],
		isCatalogLoading: Bool,
		searchText: String,
		sortOption: SourceAppsView.SortOption,
		sortAscending: Bool,
		showSourceBadge: Bool,
		showsDownloadButtons: Bool,
		listStore: SourceAppListStore,
		onSelect: @escaping (SourceAppsView.SourceAppSelection) -> Void
	) {
		self.sourceContexts = sourceContexts
		self.isCatalogLoading = isCatalogLoading
		self.searchText = searchText
		self.sortOption = sortOption
		self.sortAscending = sortAscending
		self.showSourceBadge = showSourceBadge
		self.showsDownloadButtons = showsDownloadButtons
		self.listStore = listStore
		self.onSelect = onSelect
		super.init()
		
	}
	
	isolated deinit {
		_prepareTask?.cancel()
		for observer in _dateObservers { NotificationCenter.default.removeObserver(observer) }
	}

	func attach(to tableView: UITableView) {
		uiTableView = tableView
		_dataSource = DataSource(tableView: tableView) { [weak self] table, indexPath, id in
			let cell = table.dequeueReusableCell(withIdentifier: "AppCell", for: indexPath)
			guard let self else { return cell }
			if id.source == Self.loadingSection {
				self.configureSkeletonCell(cell)
			} else if let row = self._displayed?.rows[id] ?? self._previousDisplay?.rows[id] {
				self.configureVisibleCell(cell, row: row)
			}
			return cell
		}
		showLoadingList()
		// Relative labels update on midnight/foreground without a repeating timer.
		for name in [UIApplication.significantTimeChangeNotification, UIApplication.willEnterForegroundNotification,
			NSLocale.currentLocaleDidChangeNotification] {
			_dateObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
				MainActor.assumeIsolated { self?.updateDateContext() }
			})
		}
		prepareList()
	}

	private func showLoadingList() {
		guard !_hasAppliedList else { return }
		let title = sortOption == .default ? "" : String.localized("Today")
		guard _loadingSections.first?.title != title else { return }
		if _loadingDeadline == nil { _loadingDeadline = .now + .milliseconds(300) }
		var loading = NSDiffableDataSourceSnapshot<String, SourceAppRowID>()
		_loadingSections = [.init(title: title, rows: (0..<8).map {
			SourceAppRowID(source: Self.loadingSection, identity: "loading", occurrence: $0)
		}, date: nil)]
		for section in _loadingSections {
			loading.appendSections([section.title])
			loading.appendItems(section.rows, toSection: section.title)
		}
		_dataSource?.apply(loading, animatingDifferences: false)
	}


	private func configureSkeletonCell(_ cell: UITableViewCell) {
		cell.selectionStyle = .none
		cell.accessoryType = showsDownloadButtons ? .none : .disclosureIndicator
		cell.backgroundConfiguration = .listCell()
		let showsDownload = showsDownloadButtons
		var configuration = UIHostingConfiguration { SourceAppsSkeletonRow(showsDownloadButton: showsDownload) }
		if let inset = horizontalInset.points { configuration = configuration.margins(.horizontal, inset) }
		cell.contentConfiguration = configuration
		cell.isAccessibilityElement = false
	}

	private func configureVisibleCell(_ cell: UITableViewCell, row: SourceAppRow) {
		let showBadge = showSourceBadge
		let showDownload = showsDownloadButtons
		cell.selectionStyle = .default
		cell.isAccessibilityElement = true
		cell.accessoryType = showDownload ? .none : .disclosureIndicator
		// A cell needs repository metadata, not its entire app/news catalog.
		var source = row.source
		source.apps = []
		source.news = nil
		cell.backgroundConfiguration = .listCell()
		var configuration = UIHostingConfiguration {
			SourceAppsCellView(sourceURL: row.sourceURL, source: source, app: row.app, showSourceBadge: showBadge, showsDownloadButton: showDownload)
				.tint(Color(hex: UserDefaults.standard.string(forKey: "Aether.userTintColor") ?? "#848ef9"))
		}
		if let inset = horizontalInset.points { configuration = configuration.margins(.horizontal, inset) }
		cell.contentConfiguration = configuration
	}

	// Update only visible controls; changing appearance must not rebuild the
	// catalog projection or reset its search, grouping, or scroll position.
	func refreshVisibleAccessories() {
		guard let table = uiTableView else { return }
		for indexPath in table.indexPathsForVisibleRows ?? [] {
			guard let cell = table.cellForRow(at: indexPath) else { continue }
			if let row = row(at: indexPath) {
				configureVisibleCell(cell, row: row)
			} else if _dataSource?.itemIdentifier(for: indexPath)?.source == Self.loadingSection {
				configureSkeletonCell(cell)
			}
		}
	}

	func prepareList(debouncingSearch: Bool = false, preserveScroll: Bool = false, refreshVisibleRows: Bool = false, fadeSearchResults: Bool = false) {
		_prepareTask?.cancel()
		guard !isCatalogLoading || !sourceContexts.isEmpty else { return }
		_generation += 1
		let generation = _generation
		if !_hasAppliedList { showLoadingList() }
		let contexts = sourceContexts
		let query = searchText
		let sort = sortOption.rawValue
		let ascending = sortAscending
		let previous = _displayed
		let store = listStore
		_prepareTask = Task { [weak self] in
			do {
				if debouncingSearch { try await Task.sleep(for: .milliseconds(120)) }
				let list = try await store.list(contexts: contexts, sort: sort, ascending: ascending,
					query: query, unknownDate: .localized("Unknown Date"))
				guard !Task.isCancelled, let self, self._generation == generation else { return }
				let changed = await store.changedRows(in: list, comparedTo: previous)
				if !self._hasAppliedList, let deadline = self._loadingDeadline {
					try await Task.sleep(until: deadline, clock: .continuous)
				}
				guard !Task.isCancelled, self._generation == generation else { return }
				self.apply(list, changed: changed, preserveScroll: preserveScroll, refreshVisibleRows: refreshVisibleRows, fadeSearchResults: fadeSearchResults)
			} catch is CancellationError {
				// A newer query/catalog owns the next update.
			} catch {
				// Projection preparation only throws cancellation; leave the displayed snapshot intact.
			}
		}
	}

	private func apply(_ list: PreparedSourceAppList, changed: [SourceAppRowID], preserveScroll: Bool, refreshVisibleRows: Bool, fadeSearchResults: Bool) {
		guard let table = uiTableView, let dataSource = _dataSource else { return }
		let isFirst = !_hasAppliedList
		let loadingSnapshot = isFirst && !UIAccessibility.isReduceMotionEnabled
			? table.snapshotView(afterScreenUpdates: false) : nil
		if let loadingSnapshot {
			loadingSnapshot.frame = table.bounds
			loadingSnapshot.isUserInteractionEnabled = false
			table.addSubview(loadingSnapshot)
		}
		let generation = _generation
		let anchor: (SourceAppRowID, CGFloat)? = preserveScroll && !table.isDragging && !table.isDecelerating
			? table.indexPathsForVisibleRows?.sorted().compactMap { indexPath in
				guard let id = dataSource.itemIdentifier(for: indexPath), list.rows[id] != nil else { return nil }
				return (id, table.rectForRow(at: indexPath).minY - table.contentOffset.y)
			}.first : nil
		_previousDisplay = _displayed
		_displayed = list
		dataSource.showsAlphabeticalIndex = sortOption == .name
		var snapshot = NSDiffableDataSourceSnapshot<String, SourceAppRowID>()
		for section in list.sections {
			snapshot.appendSections([section.title])
			snapshot.appendItems(section.rows, toSection: section.title)
		}
		var reconfigure = Set(changed)
		if refreshVisibleRows {
			for indexPath in table.indexPathsForVisibleRows ?? [] {
				if let id = dataSource.itemIdentifier(for: indexPath), list.rows[id] != nil { reconfigure.insert(id) }
			}
		}
		snapshot.reconfigureItems(Array(reconfigure))
		_hasAppliedList = true
		// On iOS 15+, a nonanimated diff still inserts/deletes/reconfigures individual rows.
		// Applying consistently on main keeps UIKit cell providers and model reads synchronized.
		let update = {
			let completion: () -> Void = { [weak self, weak table] in
				guard let self, let table else { loadingSnapshot?.removeFromSuperview(); return }
				if let loadingSnapshot {
					table.layoutIfNeeded()
					table.bringSubviewToFront(loadingSnapshot)
					UIView.animate(withDuration: 0.2, animations: { loadingSnapshot.alpha = 0 }) { _ in
						loadingSnapshot.removeFromSuperview()
					}
				}
				if self._generation == generation {
					self._previousDisplay = nil
					self.refreshVisibleHeaders()
				}
				if self._generation == generation, let (id, distance) = anchor, let indexPath = dataSource.indexPath(for: id), !table.isDragging && !table.isDecelerating {
					table.layoutIfNeeded()
					let minimum = -table.adjustedContentInset.top
					let maximum = max(minimum, table.contentSize.height - table.bounds.height + table.adjustedContentInset.bottom)
					let y = min(maximum, max(minimum, table.rectForRow(at: indexPath).minY - distance))
					table.setContentOffset(CGPoint(x: table.contentOffset.x, y: y), animated: false)
				}
			}
			if isFirst {
				dataSource.applySnapshotUsingReloadData(snapshot, completion: completion)
			} else {
				dataSource.apply(snapshot, animatingDifferences: false, completion: completion)
			}
		}
		if fadeSearchResults && !isFirst && !UIAccessibility.isReduceMotionEnabled {
			// Crossfade the visible viewport; never animate thousands of row deletions.
			UIView.transition(with: table, duration: 0.2,
				options: [.transitionCrossDissolve, .beginFromCurrentState, .allowUserInteraction],
				animations: { update(); table.layoutIfNeeded() })
		} else {
			update()
		}
	}

	private func row(at indexPath: IndexPath) -> SourceAppRow? {
		guard let id = _dataSource?.itemIdentifier(for: indexPath) else { return nil }
		return _displayed?.rows[id]
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

		if _newsHeaderSignature == signature, _newsHeaderWidth == width, _newsHeaderController != nil { return }

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
	
	func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
		tableView.deselectRow(at: indexPath, animated: true)

		guard let entry = row(at: indexPath) else { return }

		onSelect(
			SourceAppsView.SourceAppSelection(
				sourceObjectURI: entry.sourceObjectURI,
				appLocator: .locator(for: entry.app)
			)
		)
	}
	
	private func sectionTitle(at section: Int) -> String {
		let sections = _hasAppliedList ? (_displayed?.sections ?? []) : _loadingSections
		return sections.indices.contains(section) ? sections[section].title : ""
	}

	func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
		sectionTitle(at: section).isEmpty ? .leastNormalMagnitude : UITableView.automaticDimension
	}

	func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
		guard !sectionTitle(at: section).isEmpty else { return nil }
		guard let header = tableView.dequeueReusableHeaderFooterView(withIdentifier: "SectionHeader") else { return nil }
		configureHeader(header, section: section)
		return header
	}

	private func updateDateContext() {
		let signature = Locale.current.identifier + "|" + TimeZone.current.identifier
		if signature != _dateContextSignature {
			_dateContextSignature = signature
			prepareList(preserveScroll: true)
		} else {
			refreshVisibleHeaders()
		}
	}

	private func refreshVisibleHeaders() {
		guard let table = uiTableView else { return }
		for section in Set((table.indexPathsForVisibleRows ?? []).map(\.section)) {
			if let header = table.headerView(forSection: section) { configureHeader(header, section: section) }
		}
	}

	private func configureHeader(_ header: UITableViewHeaderFooterView, section: Int) {
		if !_hasAppliedList {
			let title = _loadingSections.indices.contains(section)
				? _loadingSections[section].displayTitle(today: .localized("Today"), yesterday: .localized("Yesterday")) : ""
			header.backgroundConfiguration = .clear()
			header.contentConfiguration = UIHostingConfiguration {
				SourceAppDateChip(title: title)
					.redacted(reason: .placeholder)
					.modifier(SourceAppsSkeletonPulse()).accessibilityHidden(true)
			}.margins(.vertical, 0)
			return
		}
		guard let sections = _displayed?.sections, sections.indices.contains(section) else { return }
		let title = sections[section].displayTitle(today: .localized("Today"), yesterday: .localized("Yesterday"))
		header.backgroundConfiguration = .clear()
		header.contentConfiguration = UIHostingConfiguration {
			SourceAppDateChip(title: title)
		}
		.margins(.vertical, 0)
	}

	func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
		.leastNormalMagnitude
	}

	func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
		guard let entry = row(at: indexPath) else { return nil }

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
						Task {
							_ = await DownloadManager.shared.startDownload(
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
