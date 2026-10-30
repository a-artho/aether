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
import os

private let sourceAppsTableSignpostLog = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "Aether", category: "SourceAppsTable")

private final class SourceAppTableCell: UITableViewCell {
	override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
		super.init(style: style, reuseIdentifier: reuseIdentifier)
		automaticallyUpdatesBackgroundConfiguration = false
	}

	required init?(coder: NSCoder) {
		super.init(coder: coder)
		automaticallyUpdatesBackgroundConfiguration = false
	}

	override func updateConfiguration(using state: UICellConfigurationState) {
		super.updateConfiguration(using: state)

		var background = UIBackgroundConfiguration.listCell().updated(for: state)
		if !state.isHighlighted && !state.isSelected {
			background.backgroundColor = .clear
		}
		backgroundConfiguration = background
	}

	// These rows have no responder editing actions. Their copy/download menus are
	// supplied by the table delegate. UIKit's default implementation searches its
	// tentative-cell map for each accessibility attribute, quadratically on large lists.
	override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool { false }
}

/// Uses the same hosting margins, typography and native section layout as real rows.
private struct SourceAppsSkeletonRow: View {
	@AppStorage("Aether.rowIconSize") private var rowIconSize: RowIconSize = .medium
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

/// UIKit may invoke its completion even when registration reports false.
/// Keep the continuation one-shot for both immediate and delayed callbacks.
@MainActor
private final class SourceNavigationTransitionReply {
	private var continuation: CheckedContinuation<Void, Never>?
	init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
	func finish() {
		let pending = continuation
		continuation = nil
		pending?.resume()
	}
}

// MARK: - Representable
struct SourceAppsTableRepresentableView: UIViewRepresentable {
	@AppStorage("Aether.rowHorizontalInset") private var horizontalInset: RowHorizontalInset = .standard
	@AppStorage("Aether.rowSeparators") private var rowSeparators: AppRowSeparatorStyle = .standard
	@AppStorage("Aether.showRepoDownloadButtons") private var showsDownloadButtons = true
	@AppStorage("Aether.userTintColor") private var themeHex = "#848ef9"
	var sourceContexts: [SourceAppsView.SourceRepositoryContext]
	var isCatalogLoading = false
	var isSearchPresented = false
	@Binding var searchText: String
	@Binding var sortOption: SourceAppsView.SortOption
	var sortAscending: Bool
	var showSourceBadge: Bool = false
	var listStore: SourceAppListStore = .shared
	var onSelect: (SourceAppsView.SourceAppSelection) -> Void
	
	func makeUIView(context: Context) -> UITableView {
		let tableView = UITableView(frame: .zero, style: .plain)
		rowSeparators.apply(to: tableView)
		// Native plain-table headers remain pinned until the next section replaces them.
		tableView.backgroundColor = .clear
		tableView.isOpaque = false
		tableView.topEdgeEffect.style = .soft
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
		rowSeparators.apply(to: tableView)
		context.coordinator.uiTableView = tableView
		context.coordinator.onSelect = onSelect
		
		let searchWasPresented = context.coordinator.isSearchPresented
		let sourcesChanged = context.coordinator.sourceContexts != sourceContexts
		let loadingChanged = context.coordinator.isCatalogLoading != isCatalogLoading
		let searchChanged = context.coordinator.searchText != searchText
		let searchPresentationChanged = searchWasPresented != isSearchPresented
		let sortOptionChanged = context.coordinator.sortOption != sortOption
		let sortDirectionChanged = context.coordinator.sortAscending != sortAscending
		let badgeChanged = context.coordinator.showSourceBadge != showSourceBadge
		let accessoryChanged = context.coordinator.showsDownloadButtons != showsDownloadButtons || context.coordinator.themeHex != themeHex || context.coordinator.horizontalInset != horizontalInset
		
		context.coordinator.sourceContexts = sourceContexts
		context.coordinator.isCatalogLoading = isCatalogLoading
		context.coordinator.isSearchPresented = isSearchPresented
		context.coordinator.searchText = searchText
		context.coordinator.sortOption = sortOption
		context.coordinator.sortAscending = sortAscending
		context.coordinator.showSourceBadge = showSourceBadge
		context.coordinator.showsDownloadButtons = showsDownloadButtons
		context.coordinator.themeHex = themeHex
		context.coordinator.horizontalInset = horizontalInset
		if accessoryChanged { context.coordinator.refreshVisibleAccessories() }
		
		if searchPresentationChanged && searchWasPresented && !isSearchPresented {
			context.coordinator.endSearch()
		} else if searchChanged && searchText.isEmpty && isSearchPresented {
			context.coordinator.restoreBaseForEmptyQuery()
		} else if sourcesChanged || loadingChanged || searchChanged || sortOptionChanged || sortDirectionChanged || badgeChanged {
			context.coordinator.prepareList(
				debouncingSearch: searchChanged && !sourcesChanged && !sortOptionChanged && !sortDirectionChanged && !badgeChanged,
				preserveScroll: sourcesChanged && !searchChanged && !sortOptionChanged && !sortDirectionChanged,
				refreshVisibleRows: badgeChanged,
				fadeSearchResults: searchChanged && !searchText.isEmpty,
				reloadData: sourcesChanged || sortOptionChanged || sortDirectionChanged || badgeChanged
			)
		}
	}
	
	func makeCoordinator() -> Coordinator {
		Coordinator(
			sourceContexts: sourceContexts,
			isCatalogLoading: isCatalogLoading,
			isSearchPresented: isSearchPresented,
			searchText: searchText,
			sortOption: sortOption,
			sortAscending: sortAscending,
			showSourceBadge: showSourceBadge,
			showsDownloadButtons: showsDownloadButtons,
			listStore: listStore,
			onSelect: onSelect
		)
	}

	static func dismantleUIView(_ tableView: UITableView, coordinator: Coordinator) {
		coordinator.shutdown(from: tableView)
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
	var isSearchPresented: Bool
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
	private var _basePresentation: SourceAppPresentation?
	private var _basePresentationKey: PresentationKey?
	private var _displayedPresentationKey: PresentationKey?
	private var _displayedQuery = ""
	private var _prepareTask: Task<Void, Never>?
	private var _generation = 0
	private var _hasAppliedList = false
	private var _didShowLoadingList = false
	private var _loadingDeadline: ContinuousClock.Instant?
	private static let loadingSection = "aether-loading"
	private var _loadingSections: [PreparedSourceAppList.Section] = []
	private var _dateObservers: [NSObjectProtocol] = []
	private var _dateContextSignature = Locale.current.identifier + "|" + TimeZone.current.identifier
	private var _isShutdown = false
	weak var uiTableView: UITableView?
	private var _openSignpostID: OSSignpostID?
	private var _searchRestoreSignpostID: OSSignpostID?
	private var _didSignpostFirstVisibleCell = false

	private struct PresentationKey: Equatable {
		let contexts: [SourceAppCatalogContext]
		let sort: String
		let ascending: Bool
		let unknownDate: String
		let locale: String
		let timeZone: String
	}

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
		isSearchPresented: Bool,
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
		self.isSearchPresented = isSearchPresented
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
		guard !_isShutdown else { return }
		uiTableView = tableView
		let openSignpostID = OSSignpostID(log: sourceAppsTableSignpostLog)
		_openSignpostID = openSignpostID
		os_signpost(.begin, log: sourceAppsTableSignpostLog, name: "Repository table opening", signpostID: openSignpostID)
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
		if shouldShowLoadingList { showLoadingList() }
		// Relative labels update on midnight/foreground without a repeating timer.
		for name in [UIApplication.significantTimeChangeNotification, UIApplication.willEnterForegroundNotification,
			NSLocale.currentLocaleDidChangeNotification] {
			_dateObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
				MainActor.assumeIsolated { self?.updateDateContext() }
			})
		}
		prepareList()
	}

	private var shouldShowLoadingList: Bool { isCatalogLoading && sourceContexts.isEmpty }

	private func presentationKey(unknownDate: String) -> PresentationKey {
		PresentationKey(contexts: sourceContexts, sort: sortOption.rawValue,
			ascending: sortAscending, unknownDate: unknownDate,
			locale: Locale.current.identifier, timeZone: TimeZone.current.identifier)
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
		_didShowLoadingList = true
	}


	private func configureSkeletonCell(_ cell: UITableViewCell) {
		cell.selectionStyle = .none
		cell.accessoryType = showsDownloadButtons ? .none : .disclosureIndicator
		cell.setNeedsUpdateConfiguration()
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
		cell.isAccessibilityElement = false
		cell.accessoryType = showDownload ? .none : .disclosureIndicator
		// SourceAppListStore has already reduced this to repository metadata.
		let source = row.source
		let selection = SourceAppsView.SourceAppSelection(
			sourceObjectURI: row.sourceObjectURI,
			appLocator: .locator(for: row.app)
		)
		cell.setNeedsUpdateConfiguration()
		var configuration = UIHostingConfiguration {
			SourceAppsCellView(sourceURL: row.sourceURL, source: source, app: row.app,
				showSourceBadge: showBadge, showsDownloadButton: showDownload,
				selectionOwner: .tableView, onSelect: { [weak self] in
					guard let self, !self._isShutdown else { return }
					self.onSelect(selection)
				})
				.tint(Color(hex: UserDefaults.standard.string(forKey: "Aether.userTintColor") ?? "#848ef9"))
		}
		if let inset = horizontalInset.points { configuration = configuration.margins(.horizontal, inset) }
		cell.contentConfiguration = configuration
	}

	// Update only visible controls; changing appearance must not rebuild the
	// catalog projection or reset its search, grouping, or scroll position.
	func refreshVisibleAccessories() {
		guard !_isShutdown, let table = uiTableView else { return }
		for indexPath in table.indexPathsForVisibleRows ?? [] {
			guard let cell = table.cellForRow(at: indexPath) else { continue }
			if let row = row(at: indexPath) {
				configureVisibleCell(cell, row: row)
			} else if _dataSource?.itemIdentifier(for: indexPath)?.source == Self.loadingSection {
				configureSkeletonCell(cell)
			}
		}
	}

	func prepareList(
		debouncingSearch: Bool = false, preserveScroll: Bool = false,
		refreshVisibleRows: Bool = false, fadeSearchResults: Bool = false,
		reloadData: Bool = false
	) {
		guard !_isShutdown else { return }
		_prepareTask?.cancel()
		if !searchText.isEmpty { finishSearchRestoreSignpost() }
		guard !isCatalogLoading || !sourceContexts.isEmpty else { return }
		_generation += 1
		let generation = _generation
		let contexts = sourceContexts
		let query = searchText
		let sort = sortOption.rawValue
		let ascending = sortAscending
		let unknownDate = String.localized("Unknown Date")
		let key = presentationKey(unknownDate: unknownDate)

		if query.isEmpty, let base = _basePresentation, _basePresentationKey == key {
			restore(base, key: key)
			return
		}

		if shouldShowLoadingList && !_hasAppliedList { showLoadingList() }
		let previous = _displayed
		let store = listStore
		let includeBase = query.isEmpty || _basePresentationKey != key
		_prepareTask = Task { [weak self] in
			let signpostID = OSSignpostID(log: sourceAppsTableSignpostLog)
			os_signpost(.begin, log: sourceAppsTableSignpostLog, name: "Coordinator list request", signpostID: signpostID,
				"queryLength=%{public}d", query.count)
			defer { os_signpost(.end, log: sourceAppsTableSignpostLog, name: "Coordinator list request", signpostID: signpostID) }
			do {
				if debouncingSearch { try await Task.sleep(for: .milliseconds(120)) }
				let result = try await store.presentation(contexts: contexts, sort: sort,
					ascending: ascending, query: query, unknownDate: unknownDate,
					includeBase: includeBase, comparedTo: previous)
				guard !Task.isCancelled, let self, self._generation == generation else { return }
				if !self._hasAppliedList, let deadline = self._loadingDeadline {
					try await Task.sleep(until: deadline, clock: .continuous)
				}
				if !self._hasAppliedList { await self.waitForOpeningNavigationTransition() }
				guard !Task.isCancelled, !self._isShutdown, self._generation == generation else { return }
				if let base = result.base {
					self._basePresentation = base
					self._basePresentationKey = key
				}
				self.apply(result.current, key: key, query: query, preserveScroll: preserveScroll,
					refreshVisibleRows: refreshVisibleRows, fadeSearchResults: fadeSearchResults,
					reloadData: reloadData)
			} catch is CancellationError {
				// A newer query/catalog owns the next update.
			} catch {
				// Projection preparation only throws cancellation; leave the displayed snapshot intact.
				self?.finishSearchRestoreSignpost()
			}
		}
	}

	/// Preparing a catalog can run during the push, but hosting its real cells
	/// and reloading the table should not compete with the native bar animation.
	private func waitForOpeningNavigationTransition() async {
		var responder: UIResponder? = uiTableView
		while let current = responder {
			if let controller = current as? UIViewController,
				let transition = controller.navigationController?.transitionCoordinator,
				transition.isAnimated {
				await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
					let reply = SourceNavigationTransitionReply(continuation)
					let registered = transition.animate(alongsideTransition: nil) { _ in reply.finish() }
					if !registered { reply.finish() }
				}
				return
			}
			responder = current.next
		}
	}

	/// Search dismissal and an empty query restore the active screen's base snapshot.
	/// The generation changes synchronously so no older filtered result can be applied.
	func endSearch() { restoreBaseForEmptyQuery() }

	func restoreBaseForEmptyQuery() {
		guard !_isShutdown else { return }
		if _searchRestoreSignpostID == nil {
			let signpostID = OSSignpostID(log: sourceAppsTableSignpostLog)
			_searchRestoreSignpostID = signpostID
			os_signpost(.begin, log: sourceAppsTableSignpostLog, name: "Repository search dismissal", signpostID: signpostID)
		}
		_prepareTask?.cancel()
		_prepareTask = nil
		_generation += 1
		let generation = _generation
		let unknownDate = String.localized("Unknown Date")
		let key = presentationKey(unknownDate: unknownDate)
		if let base = _basePresentation, _basePresentationKey == key {
			restore(base, key: key)
			return
		}

		let contexts = sourceContexts
		let sort = sortOption.rawValue
		let ascending = sortAscending
		let previous = _displayed
		let store = listStore
		_prepareTask = Task { [weak self] in
			do {
				let result = try await store.presentation(contexts: contexts, sort: sort,
					ascending: ascending, query: "", unknownDate: unknownDate,
					includeBase: true, comparedTo: previous)
				guard !Task.isCancelled, let self, self._generation == generation,
					!self._isShutdown else { return }
				self._basePresentation = result.current
				self._basePresentationKey = key
				self.restore(result.current, key: key)
			} catch is CancellationError {
				// A subsequent query or catalog revision owns the next presentation.
			} catch {
				// Keep the current table intact if preparation fails.
			}
		}
	}

	private func restore(_ presentation: SourceAppPresentation, key: PresentationKey) {
		guard !_isShutdown, let table = uiTableView, let dataSource = _dataSource else { return }
		if _displayedQuery.isEmpty, _displayedPresentationKey == key {
			finishSearchRestoreSignpost()
			return
		}
		_prepareTask?.cancel()
		_prepareTask = nil
		_generation += 1
		let generation = _generation
		_previousDisplay = _displayed
		_displayed = presentation.list
		_displayedPresentationKey = key
		_displayedQuery = ""
		dataSource.showsAlphabeticalIndex = sortOption == .name
		_hasAppliedList = true
		_didShowLoadingList = false
		_loadingDeadline = nil
		let applySignpostID = OSSignpostID(log: sourceAppsTableSignpostLog)
		os_signpost(.begin, log: sourceAppsTableSignpostLog, name: "Restore base repository snapshot", signpostID: applySignpostID,
			"rows=%{public}d", presentation.list.rows.count)
		dataSource.applySnapshotUsingReloadData(presentation.snapshot) { [weak self, weak table] in
			os_signpost(.end, log: sourceAppsTableSignpostLog, name: "Restore base repository snapshot", signpostID: applySignpostID)
			guard let self else { return }
			self.finishSearchRestoreSignpost()
			guard let table, !self._isShutdown,
				self.uiTableView === table, self._generation == generation else { return }
			self._previousDisplay = nil
			self.refreshVisibleHeaders()
		}
	}

	private func apply(
		_ presentation: SourceAppPresentation, key: PresentationKey, query: String,
		preserveScroll: Bool, refreshVisibleRows: Bool, fadeSearchResults: Bool, reloadData: Bool
	) {
		guard !_isShutdown, let table = uiTableView, let dataSource = _dataSource else { return }
		let isFirst = !_hasAppliedList
		let loadingSnapshot = isFirst && _didShowLoadingList && !UIAccessibility.isReduceMotionEnabled
			? table.snapshotView(afterScreenUpdates: false) : nil
		if loadingSnapshot != nil {
			os_signpost(.event, log: sourceAppsTableSignpostLog, name: "Capture loading transition image")
		}
		if let loadingSnapshot {
			loadingSnapshot.frame = table.bounds
			loadingSnapshot.isUserInteractionEnabled = false
			table.addSubview(loadingSnapshot)
		}
		let generation = _generation
		let anchor: (SourceAppRowID, CGFloat)? = preserveScroll && !table.isDragging && !table.isDecelerating
			? table.indexPathsForVisibleRows?.sorted().compactMap { indexPath in
				guard let id = dataSource.itemIdentifier(for: indexPath), presentation.list.rows[id] != nil else { return nil }
				return (id, table.rectForRow(at: indexPath).minY - table.contentOffset.y)
			}.first : nil
		_previousDisplay = _displayed
		_displayed = presentation.list
		_displayedPresentationKey = key
		_displayedQuery = query
		if query.isEmpty {
			_basePresentation = presentation
			_basePresentationKey = key
		}
		dataSource.showsAlphabeticalIndex = sortOption == .name
		var snapshot = presentation.snapshot
		if refreshVisibleRows {
			var reconfigure = Set<SourceAppRowID>()
			for indexPath in table.indexPathsForVisibleRows ?? [] {
				if let id = dataSource.itemIdentifier(for: indexPath), presentation.list.rows[id] != nil { reconfigure.insert(id) }
			}
			if !reconfigure.isEmpty { snapshot.reconfigureItems(Array(reconfigure)) }
		}
		_hasAppliedList = true
		_didShowLoadingList = false
		_loadingDeadline = nil
		// Search results are prepared off-main; avoid diffing them against a large catalog on the main thread.
		let update = {
			let applySignpostID = OSSignpostID(log: sourceAppsTableSignpostLog)
			os_signpost(.begin, log: sourceAppsTableSignpostLog, name: "UIKit snapshot application", signpostID: applySignpostID,
				"rows=%{public}d", presentation.list.rows.count)
			let completion: () -> Void = { [weak self, weak table] in
				os_signpost(.end, log: sourceAppsTableSignpostLog, name: "UIKit snapshot application", signpostID: applySignpostID)
				guard let self, let table,
					!self._isShutdown, self.uiTableView === table,
					self._generation == generation else {
					loadingSnapshot?.removeFromSuperview()
					return
				}
				if let loadingSnapshot {
					table.bringSubviewToFront(loadingSnapshot)
					UIView.animate(withDuration: 0.2, animations: { loadingSnapshot.alpha = 0 }) { _ in
						loadingSnapshot.removeFromSuperview()
					}
				}
				self._previousDisplay = nil
				if isFirst, let openSignpostID = self._openSignpostID {
					os_signpost(.end, log: sourceAppsTableSignpostLog, name: "Repository table opening", signpostID: openSignpostID)
					self._openSignpostID = nil
				}
				self.refreshVisibleHeaders()
				if let (id, distance) = anchor, let indexPath = dataSource.indexPath(for: id), !table.isDragging && !table.isDecelerating {
					table.layoutIfNeeded()
					let minimum = -table.adjustedContentInset.top
					let maximum = max(minimum, table.contentSize.height - table.bounds.height + table.adjustedContentInset.bottom)
					let y = min(maximum, max(minimum, table.rectForRow(at: indexPath).minY - distance))
					table.setContentOffset(CGPoint(x: table.contentOffset.x, y: y), animated: false)
				}
			}
			if isFirst || reloadData || !query.isEmpty {
				dataSource.applySnapshotUsingReloadData(snapshot, completion: completion)
			} else {
				dataSource.apply(snapshot, animatingDifferences: false, completion: completion)
			}
		}
		if fadeSearchResults && !isFirst && !UIAccessibility.isReduceMotionEnabled {
			// Crossfade the visible viewport; never animate thousands of row deletions.
			UIView.transition(with: table, duration: 0.2,
				options: [.transitionCrossDissolve, .beginFromCurrentState, .allowUserInteraction],
				animations: update)
		} else {
			update()
		}
	}

	private func row(at indexPath: IndexPath) -> SourceAppRow? {
		guard let id = _dataSource?.itemIdentifier(for: indexPath) else { return nil }
		return _displayed?.rows[id]
	}

	func shutdown(from tableView: UITableView) {
		guard !_isShutdown else { return }
		_isShutdown = true
		_generation += 1
		_prepareTask?.cancel()
		_prepareTask = nil
		finishSearchRestoreSignpost()
		if let openSignpostID = _openSignpostID {
			os_signpost(.end, log: sourceAppsTableSignpostLog, name: "Repository table opening", signpostID: openSignpostID)
			_openSignpostID = nil
		}
		for observer in _dateObservers { NotificationCenter.default.removeObserver(observer) }
		_dateObservers.removeAll(keepingCapacity: false)
		if tableView.delegate === self { tableView.delegate = nil }
		if let dataSource = _dataSource, tableView.dataSource === dataSource {
			tableView.dataSource = nil
		}
		uiTableView = nil
		_dataSource = nil
		_displayed = nil
		_previousDisplay = nil
		_basePresentation = nil
		_loadingSections.removeAll(keepingCapacity: false)
		_loadingDeadline = nil
		sourceContexts.removeAll(keepingCapacity: false)
		onSelect = { _ in }
	}

	private func finishSearchRestoreSignpost() {
		guard let signpostID = _searchRestoreSignpostID else { return }
		os_signpost(.end, log: sourceAppsTableSignpostLog, name: "Repository search dismissal", signpostID: signpostID)
		_searchRestoreSignpostID = nil
	}
	
	// MARK: TableView
	
	func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
		tableView.deselectRow(at: indexPath, animated: true)

		guard !_isShutdown, let entry = row(at: indexPath) else { return }

		onSelect(
			SourceAppsView.SourceAppSelection(
				sourceObjectURI: entry.sourceObjectURI,
				appLocator: .locator(for: entry.app)
			)
		)
	}

	func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
		guard !_isShutdown, !_didSignpostFirstVisibleCell,
			_dataSource?.itemIdentifier(for: indexPath)?.source != Self.loadingSection else { return }
		_didSignpostFirstVisibleCell = true
		os_signpost(.event, log: sourceAppsTableSignpostLog, name: "First repository app row displayed",
			signpostID: _openSignpostID ?? .exclusive)
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
		guard !_isShutdown else { return }
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
			
			var actions: [UIMenuElement] = []
			let provenance = SourceAppProvenance(sourceURL: entry.sourceURL, repository: entry.source, app: entry.app)
			if SourceLibraryDownloads.shared.contains(provenance), let url = entry.app.currentDownloadUrl {
				actions.append(UIAction(title: .localized("Download Again"), image: UIImage(systemName: "arrow.down")) { _ in
					Task {
						_ = await DownloadManager.shared.startDownload(from: url,
							id: entry.app.currentUniqueId, sourceProvenance: provenance)
					}
				})
			}
			actions.append(contentsOf: [downloadsMenu, versionsMenu])
			return UIMenu(children: actions)
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
