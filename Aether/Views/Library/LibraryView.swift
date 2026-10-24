//
//  LibraryView.swift
//  Aether
//

import IDeviceSwift
import NimbleViews
import SwiftUI
import UIKit

@MainActor
struct LibraryView: View {
	@StateObject private var imports = UnifiedImportsController()
	@AppStorage("Aether.installationMethod") private var installationMethod = 0
	@StateObject private var store: InstalledAppsStore
	@ObservedObject private var installationManager = AppInstallationManager.shared
	@ObservedObject private var connection = DeviceConnectionManager.shared
	@ObservedObject private var cellularAssist = CellularAssistManager.shared
	@ObservedObject private var tabManager = AppTabManager.shared
	@ObservedObject private var sourcesViewModel = SourcesViewModel.shared
	@ObservedObject private var ignoredUpdates = IgnoredAppUpdates.shared
	@FetchRequest(sortDescriptors: []) private var sources: FetchedResults<AltSource>
	@State private var updateContexts: [String: [SourceAppCatalogContext]] = [:]
	@State private var libraryRefreshTask: Task<Void, Never>?
	@State private var libraryRefreshInProgress = false
	@State private var updateCheckID: UUID?
	@State private var noUpdatesUntil: Date?
	@State private var updateCheckRevision = 0

	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@State private var searchText = ""
	@State private var searchFocused = false
	@State private var toolbarWidth: CGFloat = 320
	@State private var appNavigationPath: [InstalledAppsRoute] = []
	@State private var isRootListVisible = false
	@State private var hasLoadedInitialContent = false
	@State private var visibleUnifiedInstallRows: [UUID: Set<String>] = [:]
	private let loadsApps: Bool
	private let loadsIcons: Bool

	init() {
		_store = StateObject(wrappedValue: InstalledAppsStore.shared)
		self.loadsApps = true
		self.loadsIcons = true
	}

	init(
		store: InstalledAppsStore,
		loadsApps: Bool = true,
		loadsIcons: Bool = true
	) {
		_store = StateObject(wrappedValue: store)
		self.loadsApps = loadsApps
		self.loadsIcons = loadsIcons
	}

	private enum LibrarySection: Identifiable {
		case allApps, status, imports, updates
		var id: Self { self }
	}

	private struct LibraryLayout: Equatable {
		let sections: [LibrarySection]
		let imports: [String]
		let updates: [String]
	}

	var body: some View {
		let cards = installationManager.installationCards.filter { matchesSearch($0.app.name, $0.app.identifier, $0.app.version) }
		let sideloadedApps = store.apps.filter { matchesSearch($0.name, $0.bundleIdentifier, $0.version, $0.build) }
		let showAllApps = installationMethod == 0
			? matchesSearch(String.localized("All Apps"), String.localized("Requires Local mode"))
			: !showsDevicePlaceholder && (searchText.isEmpty || !sideloadedApps.isEmpty || matchesSearch(String.localized("All Apps")))
		let appsWithUpdates = sideloadedApps.filter { !ignoredUpdates.identifiers.contains($0.bundleIdentifier) && updateContexts[$0.bundleIdentifier]?.isEmpty == false }
		let importRows = imports.visibleRows.filter { entry in
			let app = entry.app ?? entry.operation?.app ?? entry.export?.app
			return matchesSearch(app?.name, app?.identifier, app?.version,
				entry.download?.sourceProvenance?.sourceAppName, entry.download?.sourceProvenance?.sourceAppIdentifier,
				entry.download?.sourceProvenance?.sourceAppVersion, entry.download?.fileName)
		}
		let sections: [LibrarySection] = [
			showAllApps ? .allApps : nil,
			installationMethod == 1 && searchText.isEmpty && !importRows.isEmpty && showsDevicePlaceholder ? .status : nil,
			importRows.isEmpty ? nil : .imports,
			showsDevicePlaceholder || appsWithUpdates.isEmpty ? nil : .updates
		].compactMap { $0 }
		let layout = LibraryLayout(sections: sections,
			imports: importRows.map(\.id), updates: appsWithUpdates.map(\.id))
		NavigationStack(path: $appNavigationPath) {
			ScrollViewReader { scrollProxy in
				List {
					ForEach(sections) { section in
						switch section {
						case .allApps:
							allAppsRow
						case .updates:
							NBSection(String.localized("Updates")) {
								ForEach(appsWithUpdates) { app in
									NavigationLink(value: InstalledAppsRoute.updates(app.bundleIdentifier)) {
										InstalledAppCellView(app: app, loadsIcon: loadsIcons)
									}
									.buttonStyle(.plain)
									.id(app.id)
									.swipeActions(edge: .trailing, allowsFullSwipe: true) {
										Button(String.localized("Ignore"), systemImage: "bell.slash") {
											ignoredUpdates.ignore(app.bundleIdentifier)
										}
										.tint(.orange)
									}
								}
							}
							.listSectionSeparator(.hidden)
						case .status:
							compactDeviceStatus
						case .imports:
							NBSection(.localized("Imports")) {
								UnifiedImportsRows(entries: importRows, controller: imports, visibleOperation: recordVisibleImportOperation)
							}
							.listSectionSeparator(.hidden)
							.id("libraryImports")

						}
					}
				}
				.navigationBarTitleDisplayMode(.inline)
				.navigationDestination(for: InstalledAppsRoute.self) { route in
					switch route {
					case .allApps:
						AllInstalledAppsView(store: store, loadsIcons: loadsIcons,
							initialSearch: searchText, placeholder: allAppsPlaceholder)
					case let .updates(identifier):
						InstalledAppUpdatesView(contexts: updateContexts[identifier] ?? [])
					}
				}
				.listStyle(.plain)
				.onAppear { isRootListVisible = true }
				.onDisappear { isRootListVisible = false }
				.task(id: libraryFocusState) {
					guard !Task.isCancelled, let request = tabManager.libraryFocusRequest,
						tabManager.selectedTab == .library, tabManager.installationFocusRequest == nil else { return }
					var transaction = Transaction()
					transaction.disablesAnimations = true
					if !appNavigationPath.isEmpty || imports.infoApp != nil {
						withTransaction(transaction) {
							appNavigationPath.removeAll()
							imports.infoApp = nil
						}
						return
					}
					guard isRootListVisible, imports.hasRows else { return }
					withTransaction(transaction) {
						scrollProxy.scrollTo("libraryImports", anchor: .top)
					}
					tabManager.consumeLibraryFocusRequest(request)
				}
				.task(id: installationFocusState) {
					guard !Task.isCancelled, let request = tabManager.installationFocusRequest,
						tabManager.selectedTab == .library, let firstCard = cards.first else { return }
					var transaction = Transaction()
					transaction.disablesAnimations = true
					if !appNavigationPath.isEmpty || imports.infoApp != nil {
						withTransaction(transaction) {
							appNavigationPath.removeAll()
							imports.infoApp = nil
						}
						return
					}
					guard isRootListVisible else { return }
					withTransaction(transaction) {
						if let row = imports.visibleRows.first(where: { $0.operation?.id == firstCard.id }) {
							scrollProxy.scrollTo(row.id, anchor: .top)
						}
					}
					// Appearance confirms the lazy list has materialized the target.
					// Keep the request pending while navigation/layout catches up.
					if operationIsVisible(firstCard.id) {
						tabManager.consumeInstallationFocusRequest(request)
					}
				}
				.overlay {
					if !searchText.isEmpty && sections.isEmpty {
						TabPlaceholderView(title: .localized("No Results"), description: .localized("Try another search."), systemImage: "magnifyingglass")
					} else if installationMethod == 1 && searchText.isEmpty && (!imports.hasRows && showsDevicePlaceholder) {
						_placeholderContent
							.transition(.opacity)
					}
				}
				.animation(reduceMotion || !hasLoadedInitialContent ? nil : .snappy, value: layout)
				.modifier(UnifiedImportsDataSource(controller: imports))
				.refreshable {
					guard loadsApps else { return }
					startLibraryRefresh()
				}
			}
			.task {
				guard loadsApps else { return }
				async let repositories: Void = sourcesViewModel.refreshIfNeeded(Array(sources))
				async let installed: Void = store.load()
				await installed
				if !Task.isCancelled { hasLoadedInitialContent = true }
				await repositories
			}
			.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { toolbarWidth = $0 }
			.modifier(SearchToolbarModifier(
				text: $searchText, isPresented: $tabManager.isLibrarySearchPresented,
				focus: $searchFocused, title: libraryTitle, width: toolbarWidth,
				isScreenActive: isRootListVisible && appNavigationPath.isEmpty
					&& imports.infoApp == nil && imports.signingApp == nil
					&& !imports.importing && !imports.importingURL,
				isTabRoot: true, hasTitleMenu: false,
				secondaryAction: { imports.importing = true },
				secondaryURLAction: { imports.urlText = ""; imports.importingURL = true }
			) { EmptyView() })
			.onChange(of: tabManager.isLibrarySearchPresented) { _, presented in
				if !presented { searchFocused = false; searchText = "" }
			}
			.onChange(of: appNavigationPath) { _, path in
				if !path.isEmpty { searchFocused = false }
			}
			.onChange(of: tabManager.installationFocusRequest) { _, request in
				if request != nil { resetSearch() }
			}
			.onChange(of: tabManager.libraryFocusRequest) { _, request in
				if request != nil { resetSearch() }
			}
			.modifier(UnifiedImportsPresentation(controller: imports))
			.onChange(of: installationMethod) { _, mode in
				if mode == 0 { appNavigationPath.removeAll() }
			}
		}
		.task(id: updateRequest) {
			let checkID = UUID()
			updateCheckID = checkID
			noUpdatesUntil = nil
			defer { if updateCheckID == checkID { updateCheckID = nil } }
			guard loadsApps, installationMethod == 1, !store.apps.isEmpty else {
				updateContexts = [:]
				_ = try? await InstalledAppUpdateCatalog.shared.updates(installedVersions: [:], contexts: [])
				return
			}
			guard !libraryRefreshInProgress, !isLoadingInstalledApps,
				sourcesViewModel.isFinished, !sourcesViewModel.isRefreshRequested else { return }
			await sourcesViewModel.ensureSourcesLoaded(Array(sources))
			guard !Task.isCancelled else { return }
			let versions = store.apps.reduce(into: [String: String]()) { values, app in
				if let version = app.version { values[app.bundleIdentifier] = version }
			}
			let contexts = sources.compactMap { source -> SourceAppCatalogContext? in
				guard let repository = sourcesViewModel.repository(for: source) else { return nil }
				return SourceAppCatalogContext(sourceObjectURI: source.objectID.uriRepresentation().absoluteString,
					sourceURL: source.sourceURL, repository: repository, revision: sourcesViewModel.revision(for: source))
			}
			do {
				let matches = try await InstalledAppUpdateCatalog.shared.updates(installedVersions: versions, contexts: contexts, ignoredIdentifiers: ignoredUpdates.identifiers)
				try Task.checkCancellation()
				updateContexts = matches
				if matches.values.allSatisfy({ $0.isEmpty }), sourcesViewModel.refreshErrors.isEmpty,
					store.errorMessage == nil, contexts.count == sources.count {
					noUpdatesUntil = Date().addingTimeInterval(2)
				}
			} catch is CancellationError {} catch { updateContexts = [:] }
		}
		.task(id: noUpdatesUntil) {
			guard let deadline = noUpdatesUntil else { return }
			do {
				try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
				if noUpdatesUntil == deadline { noUpdatesUntil = nil }
			} catch {}
		}
	}

	private func startLibraryRefresh() {
		guard libraryRefreshTask == nil else { return }
		libraryRefreshInProgress = true
		noUpdatesUntil = nil
		let repositories = sourcesViewModel.startRefresh(Array(sources))
		libraryRefreshTask = Task { @MainActor in
			defer {
				libraryRefreshTask = nil
				libraryRefreshInProgress = false
				updateCheckRevision &+= 1
			}
			async let installed: Void = store.refresh(force: true)
			await repositories.value
			await installed
		}
	}

	private var isCheckingForUpdates: Bool {
		libraryRefreshInProgress || sourcesViewModel.isRefreshRequested || !sourcesViewModel.isFinished || updateCheckID != nil
	}

	private var isConnectingTunnel: Bool {
		connection.isUpdating || connection.isAwaitingAutomaticConnection
	}

	private var showsDevicePlaceholder: Bool {
		installationMethod == 0 || (store.apps.isEmpty && (
			!connection.hasPairingFile || connection.requiresInAppTunnelSetup
			|| (_showsCellularConnectionGuidance && _needsManualCellularRefresh)
			|| (!connection.isConnected && !isConnectingTunnel && !cellularAssist.isBusy)
		))
	}

	private var isLoadingInstalledApps: Bool {
		store.isLoading || (connection.isConnected && !store.hasLoadedApps && store.errorMessage == nil)
	}

	private var allAppsIsBusy: Bool {
		isConnectingTunnel || cellularAssist.isBusy || isLoadingInstalledApps || isCheckingForUpdates
	}

	private var allAppsSubtitle: String {
		if isConnectingTunnel || cellularAssist.isBusy {
			return .localized("Connecting Tunnel")
		}
		if isLoadingInstalledApps { return .localized("Loading Installed Apps") }
		if isCheckingForUpdates { return .localized("Checking for Updates…") }
		if noUpdatesUntil != nil { return .localized("No Updates Available") }
		return .localized("See all sideloaded apps")
	}

	private var allAppsRow: some View {
		Section {
			if installationMethod == 0 {
				HStack(spacing: 12) {
					allAppsSummary(subtitle: String.localized("Requires Local mode"))
						.opacity(0.55)
						.disabled(true)
					Button(action: _switchToIDeviceMode) {
						NBButton(String.localized("Switch"), style: .text)
					}
					.buttonStyle(.borderless)
					.disabled(installationManager.hasPendingInstalls)
					.accessibilityHint(String.localized("Switch to Local installation mode."))
				}
				.listRowSeparator(.hidden)
			} else {
				NavigationLink(value: InstalledAppsRoute.allApps) {
					HStack(spacing: 12) {
						allAppsSummary(subtitle: allAppsSubtitle)
						ZStack {
							Text(store.apps.count, format: .number)
								.font(.footnote)
								.foregroundStyle(.secondary)
								.opacity(allAppsIsBusy ? 0 : 1)
								.accessibilityHidden(allAppsIsBusy)
							if allAppsIsBusy {
								ProgressView()
									.transition(reduceMotion ? .identity : .opacity)
							}
						}
						.frame(minWidth: 20, minHeight: 20)
						.animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: allAppsIsBusy)
					}
				}
				.buttonStyle(.plain)
				.listRowSeparator(.hidden)
			}
		}
	}

	private func allAppsSummary(subtitle: String) -> some View {
		HStack(spacing: NBRowMetrics.contentSpacing) {
			OverviewRowIcon(kind: .apps)
			VStack(alignment: .leading, spacing: NBRowMetrics.lineSpacing) {
				Text(String.localized("All Apps"))
					.nbRowTitle()
					.foregroundStyle(.primary)
				Text(subtitle)
					.nbRowSubtitle()
					.foregroundStyle(.secondary)
					.contentTransition(reduceMotion ? .identity : .opacity)
					.animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: subtitle)
			}
			.padding(.vertical, NBRowMetrics.textVerticalPadding)
			.frame(maxWidth: .infinity, alignment: .leading)
		}
	}

	private func matchesSearch(_ fields: String?...) -> Bool {
		let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
		return query.isEmpty || fields.compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(query) }
	}

	private func resetSearch() {
		searchFocused = false
		searchText = ""
		tabManager.isLibrarySearchPresented = false
	}

	private var installationFocusState: [String] {
		[searchText, String(tabManager.isLibrarySearchPresented), tabManager.installationFocusRequest?.uuidString ?? "",
		 tabManager.selectedTab.rawValue,
		 installationManager.installationCards.first?.id.uuidString ?? "",
		 String(describing: appNavigationPath),
		 imports.infoApp?.id ?? "", String(isRootListVisible), String(imports.revision),
		 String(installationManager.installationCards.first.map { operationIsVisible($0.id) } ?? false)]
	}

	private var libraryFocusState: [String] {
		[searchText, String(tabManager.isLibrarySearchPresented), tabManager.libraryFocusRequest?.uuidString ?? "", tabManager.selectedTab.rawValue,
		 String(describing: appNavigationPath), String(isRootListVisible), imports.infoApp?.id ?? "", String(imports.revision)]
	}

	private func recordVisibleImportOperation(_ id: UUID, _ rowID: String, _ visible: Bool) {
		if visible { visibleUnifiedInstallRows[id, default: []].insert(rowID) }
		else { visibleUnifiedInstallRows[id]?.remove(rowID) }
		if visibleUnifiedInstallRows[id]?.isEmpty == true { visibleUnifiedInstallRows.removeValue(forKey: id) }
	}

	private func operationIsVisible(_ id: UUID) -> Bool {
		visibleUnifiedInstallRows[id]?.isEmpty == false
	}

	private var updateRequest: [String] {
		[String(installationMethod), String(sourcesViewModel.catalogRevision),
			String(store.isLoading), String(store.hasLoadedApps), String(libraryRefreshInProgress),
			String(sourcesViewModel.isFinished), String(sourcesViewModel.isRefreshRequested), String(updateCheckRevision)]
			+ ignoredUpdates.identifiers.sorted()
			+ store.apps.flatMap { [$0.bundleIdentifier, $0.version ?? ""] }
			+ sources.flatMap { [$0.objectID.uriRepresentation().absoluteString, $0.sourceURL?.absoluteString ?? ""] }
	}


	private var libraryTitle: String {
		.localized("Library")
	}

	private struct DeviceStatus {
		enum Action { case pair, setupVPN, reconnect }
		let title: String
		let description: String
		let icon: String
		var busy = false
		var action: Action?
		var buttonTitle: String?
	}

	private var deviceStatus: DeviceStatus {
		if !connection.hasPairingFile && store.apps.isEmpty {
			return DeviceStatus(title: .localized("Pairing File Missing"), description: .localized("Add a pairing file to view sideloaded apps or spoof device location."), icon: "key.slash", action: .pair, buttonTitle: .localized("Pair"))
		} else if connection.requiresInAppTunnelSetup && store.apps.isEmpty {
			return DeviceStatus(title: .localized("VPN Setup Required"), description: .localized("Set up Aether’s VPN profile to connect to your device."), icon: "network.badge.shield.half.filled", action: .setupVPN, buttonTitle: .localized("Set Up"))
		} else if _showsCellularConnectionGuidance && store.apps.isEmpty {
			return DeviceStatus(title: _needsManualCellularRefresh ? .localized("Refresh Cellular Connection") : .localized("Connecting on Cellular"), description: _needsManualCellularRefresh ? .localized("Turn off Mobile Data or briefly enable Airplane Mode. Switch it back on once Aether connects.") : .localized("Aether is refreshing the cellular connection to reach your device."), icon: "antenna.radiowaves.left.and.right", busy: true)
		} else if isConnectingTunnel && store.apps.isEmpty {
			return DeviceStatus(title: .localized("Connecting Tunnel"), description: .localized("Aether is connecting so you can view sideloaded apps or spoof device location."), icon: "network", busy: true)
		} else if !connection.isConnected && store.apps.isEmpty {
			return DeviceStatus(title: .localized("Tunnel Unavailable"), description: .localized("Reconnect the tunnel to view sideloaded apps or spoof device location."), icon: "network.slash", action: .reconnect, buttonTitle: .localized("Retry"))

		} else {
			return DeviceStatus(title: .localized("No Sideloaded Apps"), description: .localized("Sideloaded apps will appear here. Manage location spoofing in Settings."), icon: "square.stack.3d.up.slash")
		}
	}

	@ViewBuilder private var _placeholderContent: some View {
		let status = deviceStatus
		TabPlaceholderView(title: status.title, description: status.description, systemImage: status.icon) {
			deviceStatusAction(status)
		}
	}

	@ViewBuilder private var allAppsPlaceholder: some View {
		if showsDevicePlaceholder {
			_placeholderContent
		} else if allAppsIsBusy {
			ProgressView(allAppsSubtitle)
		} else if let error = store.errorMessage {
			TabPlaceholderView(title: .localized("Unable to Load Installed Apps"), description: error, systemImage: "iphone.slash") {
				Button { Task { await store.refresh(force: true) } } label: {
					NBButton(String.localized("Retry"), style: .text)
				}
			}
		} else {
			TabPlaceholderView(title: .localized("No Sideloaded Apps"), description: .localized("Sideloaded apps will appear here. Manage location spoofing in Settings."), systemImage: "square.stack.3d.up.slash")
		}
	}

	private var compactDeviceStatus: some View {
		let status = deviceStatus
		return VStack(spacing: 8) {
			HStack(spacing: 6) {
				Image(systemName: status.icon)
					.font(.subheadline).foregroundStyle(.secondary)
					.accessibilityHidden(true)
				Text(status.title)
					.font(.subheadline).foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
			}
			if !status.description.isEmpty {
				Text(status.description)
					.font(.caption).foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
					.fixedSize(horizontal: false, vertical: true)
			}
			deviceStatusAction(status)
		}
		.frame(maxWidth: .infinity)
		.padding(.vertical, 8)
		.listRowBackground(Color.clear)
		.listRowSeparator(.hidden)
		.accessibilityElement(children: .contain)
		.accessibilityHint(status.description)
	}

	@ViewBuilder private func deviceStatusAction(_ status: DeviceStatus) -> some View {
		if status.busy {
			ProgressView().controlSize(.small)
		} else if let action = status.action, let title = status.buttonTitle {
			Button { performDeviceStatusAction(action) } label: {
				NBButton(title, style: .text)
			}
			.buttonStyle(.borderless)
		}
	}

	private func performDeviceStatusAction(_ action: DeviceStatus.Action) {
		switch action {
		case .pair: tabManager.openSettings(page: .pairingFile)
		case .setupVPN: connection.setUpInAppTunnel()
		case .reconnect: connection.reconnectForIDeviceMode()
		}
	}

	private var _showsCellularConnectionGuidance: Bool {
		guard installationMethod == 1, connection.physicalNetworkState == .cellularOnly else { return false }
		if connection.tunnelMethod == .inApp {
			return cellularAssist.isBusy || cellularAssist.isWaitingForManualRecovery
		}
		// LocalDevVPN cannot be controlled by Aether's shortcut, but it hits the
		// same cellular socket condition. Keep the recovery advice in one place.
		return !connection.isConnected
	}

	private var _needsManualCellularRefresh: Bool {
		cellularAssist.isWaitingForManualRecovery || connection.tunnelMethod == .localDevVPN
	}

	private func _switchToIDeviceMode() {
		guard connection.setInstallationMode(1) else { return }
		HapticManager.shared.selection()
	}


}

struct InstalledAppCellView: View {
	@Environment(\.horizontalSizeClass) private var horizontalSizeClass
	let app: InstalledApp
	let loadsIcon: Bool

	var body: some View {
		HStack(spacing: NBRowMetrics.contentSpacing) {
			InstalledAppIconView(
				bundleIdentifier: app.bundleIdentifier,
				cacheVersion: app.iconCacheVersion,
				loadsIcon: loadsIcon
			)

			LibraryRowDetails(
				name: app.name,
				version: app.version ?? app.build,
				identifier: app.bundleIdentifier
			)
		}
		.padding(horizontalSizeClass == .compact ? 0 : 12)
		.background {
			if horizontalSizeClass != .compact {
				RoundedRectangle(cornerRadius: 18, style: .continuous)
					.fill(Color(.quaternarySystemFill))
			}
		}
		.contentShape(Rectangle())
	}

}

struct InstalledAppIconView: View {
	let bundleIdentifier: String
	let cacheVersion: String
	let loadsIcon: Bool
	@AppStorage("Aether.rowIconSize") private var rowIconSize: RowIconSize = .standard
	private var size: CGFloat { rowIconSize.points }
	@State private var image: UIImage?
	@State private var loadedIdentity: String?
	@State private var iconIsLoading = false
	@State private var iconLoadGeneration = UUID()

	var body: some View {
		Group {
			if let displayedImage = (loadedIdentity == bundleIdentifier + "|" + cacheVersion ? image : nil) ?? (loadsIcon ? InstallationAppProxy.appIconInMemory(for: bundleIdentifier, cacheVersion: cacheVersion) : nil) {
				Image(uiImage: displayedImage).appIconStyle(size: size)
			} else {
				AppIconSkeleton(size: size, isLoading: iconIsLoading)
			}
		}
		.task(id: bundleIdentifier + "|" + cacheVersion) {
			await loadIcon()
		}
	}

	private func loadIcon() async {
		guard loadsIcon, !Task.isCancelled else { return }
		let generation = UUID()
		iconLoadGeneration = generation
		iconIsLoading = true
		defer { if iconLoadGeneration == generation { iconIsLoading = false } }
		let loaded = try? await InstallationAppProxy.getAppIconCached(
			for: bundleIdentifier,
			cacheVersion: cacheVersion
		)
		guard !Task.isCancelled, iconLoadGeneration == generation else { return }
		var transaction = Transaction()
		transaction.disablesAnimations = true
		withTransaction(transaction) { image = loaded; loadedIdentity = bundleIdentifier + "|" + cacheVersion }
	}
}

#Preview("Installed Apps") {
	LibraryView(
		store: InstalledAppsStore(apps: [
			InstalledApp(
				bundleIdentifier: "com.example.video",
				name: "Video",
				version: "2.4.1",
				build: "87"
			),
			InstalledApp(
				bundleIdentifier: "com.example.music",
				name: "Music",
				version: "9.0",
				build: "104"
			)
		]),
		loadsApps: false,
		loadsIcons: false
	)
}

#Preview("No Installed Apps") {
	LibraryView(store: InstalledAppsStore(), loadsApps: false, loadsIcons: false)
}
