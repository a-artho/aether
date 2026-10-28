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
	@AppStorage("Aether.statusUnderPageTitle") private var statusUnderPageTitle = false
	@StateObject private var store: InstalledAppsStore
	@ObservedObject private var installationManager = AppInstallationManager.shared
	@ObservedObject private var connection = DeviceConnectionManager.shared
	@ObservedObject private var cellularAssist = CellularAssistManager.shared
	@ObservedObject private var tabManager = AppTabManager.shared
	@ObservedObject private var updates = LibraryUpdatesStore.shared
	@ObservedObject private var ignoredUpdates = IgnoredAppUpdates.shared

	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@State private var searchText = ""
	@State private var searchFocused = false
	@State private var appNavigationPath: [InstalledAppsRoute] = []
	@State private var isRootListVisible = false
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
		let splitGroups: [String]
		let updates: [String]
	}

	private struct LibraryProjection {
		let appsWithUpdates: [InstalledApp]
		let libraryRows: [UnifiedImportEntry]
		let splitGroups: [SplitArtifactGroup]
		let sections: [LibrarySection]
		let layout: LibraryLayout
	}

	var body: some View {
		let projection = makeLibraryProjection()
		NavigationStack(path: $appNavigationPath) {
			rootContent(projection: projection)
		}
		.modifier(FloatingNavigationAppearance())
	}

	private func makeLibraryProjection() -> LibraryProjection {
		let sideloadedApps = store.apps.filter {
			matchesSearch($0.name, $0.bundleIdentifier, $0.version, $0.build)
		}
		let showAllApps: Bool
		if installationMethod == 0 {
			showAllApps = matchesSearch(String.localized("All Apps"), String.localized("Requires Local mode"))
		} else {
			showAllApps = !showsDevicePlaceholder
				&& (searchText.isEmpty || !sideloadedApps.isEmpty || matchesSearch(String.localized("All Apps")))
		}
		let appsWithUpdates = sideloadedApps.filter {
			!ignoredUpdates.identifiers.contains($0.bundleIdentifier)
				&& updates.updateContexts[$0.bundleIdentifier]?.isEmpty == false
		}
		let visibleRows = imports.visibleRows
		let libraryRows = visibleRows.filter { entry in
			let app = entry.app ?? entry.operation?.app ?? entry.export?.app
			return matchesSearch(app?.name, app?.identifier, app?.version,
				entry.download?.sourceProvenance?.sourceAppName, entry.download?.sourceProvenance?.sourceAppIdentifier,
				entry.download?.sourceProvenance?.sourceAppVersion, entry.download?.fileName)
		}
		let splitGroups = SplitArtifactGroup.makeGroups(
			from: visibleRows,
			lineage: LibraryArtifactIndex.shared.lineage
		).filter { group in
			searchText.isEmpty || group.entries.contains { entry in
				let app = entry.app ?? entry.operation?.app ?? entry.export?.app
				return matchesSearch(app?.name, app?.identifier, app?.version,
					entry.download?.sourceProvenance?.sourceAppName, entry.download?.sourceProvenance?.sourceAppIdentifier,
					entry.download?.sourceProvenance?.sourceAppVersion, entry.download?.fileName)
			}
		}
		let splitRowIDs = Set(splitGroups.flatMap { $0.entries.map(\.id) })
		let importRows = libraryRows.filter { !splitRowIDs.contains($0.id) }
		let sections: [LibrarySection] = [
			showAllApps ? .allApps : nil,
			installationMethod == 1 && searchText.isEmpty && !libraryRows.isEmpty && showsDevicePlaceholder ? .status : nil,
			importRows.isEmpty && splitGroups.isEmpty ? nil : .imports,
			showsDevicePlaceholder || !updates.hasVerifiedUpdates || appsWithUpdates.isEmpty ? nil : .updates
		].compactMap { $0 }
		let layout = LibraryLayout(
			sections: sections,
			imports: importRows.map(\.id),
			splitGroups: splitGroups.map(\.id),
			updates: appsWithUpdates.map(\.id)
		)

		return LibraryProjection(
			appsWithUpdates: appsWithUpdates,
			libraryRows: libraryRows,
			splitGroups: splitGroups,
			sections: sections,
			layout: layout
		)
	}

	private func rootContent(projection: LibraryProjection) -> some View {
		ScrollViewReader { scrollProxy in
			libraryList(scrollProxy: scrollProxy, projection: projection)
		}
		.modifier(SearchToolbarModifier(
			text: $searchText, isPresented: $tabManager.isLibrarySearchPresented,
			focus: $searchFocused, title: libraryTitle,
			isScreenActive: isRootListVisible && appNavigationPath.isEmpty
				&& imports.infoApp == nil && imports.signingApp == nil
				&& !imports.importing && !imports.importingURL,
			isTabRoot: true, hasTitleMenu: false,
			secondaryAction: { imports.importing = true },
			secondaryURLAction: { imports.urlText = ""; imports.importingURL = true },
			titleSubtitle: libraryPageTitleSubtitle
		) { EmptyView() })
		.onChange(of: tabManager.isLibrarySearchPresented) { _, presented in
			if !presented { searchFocused = false }
		}
		.onChange(of: appNavigationPath) { _, path in
			if !path.isEmpty { searchFocused = false }
		}
		.onChange(of: tabManager.libraryFocusRequest) { _, request in
			if request != nil { resetSearch() }
		}
		.modifier(UnifiedImportsPresentation(controller: imports))
		.onChange(of: installationMethod) { _, mode in
			if mode == 0 { appNavigationPath.removeAll() }
		}
		.onChange(of: showsDevicePlaceholder) { _, shouldShowPlaceholder in
			guard shouldShowPlaceholder, appNavigationPath.contains(.allApps) else { return }
			appNavigationPath.removeAll()
		}
	}

	private func libraryList(scrollProxy: ScrollViewProxy, projection: LibraryProjection) -> some View {
		List {
			ForEach(projection.sections) { section in
				librarySectionContent(section, projection: projection)
			}
		}
		.navigationBarTitleDisplayMode(.inline)
		.navigationDestination(for: InstalledAppsRoute.self) { route in
			Group {
				switch route {
				case .allApps:
					AllInstalledAppsView(store: store, loadsIcons: loadsIcons,
						initialSearch: searchText, placeholder: allAppsPlaceholder)
				case let .updates(identifier):
					InstalledAppUpdatesView(contexts: updates.updateContexts[identifier] ?? [])
				case let .splitArtifacts(originalUUID):
					SplitArtifactsView(originalUUID: originalUUID, controller: imports)
				}
			}
		}
		.listStyle(.plain)
		.scrollContentBackground(.hidden)
		.onAppear { isRootListVisible = true }
		.onDisappear { isRootListVisible = false }
		.task(id: libraryFocusState) {
			guard !Task.isCancelled, let request = tabManager.libraryFocusRequest,
				tabManager.selectedTab == .library else { return }
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
		.animation(reduceMotion || !imports.hasLoadedInitialRows ? nil : .snappy, value: projection.layout)
		.background { AetherAmbientBackground() }
		.overlay {
			if !searchText.isEmpty && projection.sections.isEmpty {
				TabPlaceholderView(title: .localized("No Results"), description: .localized("Try another search."), systemImage: "magnifyingglass")
			} else if imports.hasLoadedInitialRows && installationMethod == 1 && searchText.isEmpty && (!imports.hasRows && showsDevicePlaceholder) {
				_placeholderContent.transition(.opacity)
			}
		}
		.modifier(UnifiedImportsDataSource(controller: imports))
		.refreshable {
			guard loadsApps else { return }
			updates.startRefresh()
		}
	}

	@ViewBuilder
	private func librarySectionContent(_ section: LibrarySection, projection: LibraryProjection) -> some View {
		switch section {
		case .allApps:
			allAppsRow
		case .updates:
			updatesSection(apps: projection.appsWithUpdates)
		case .status:
			compactDeviceStatus
		case .imports:
			importsSection(entries: projection.libraryRows, groups: projection.splitGroups)
		}
	}

	private func updatesSection(apps: [InstalledApp]) -> some View {
		NBSection(String.localized("Updates")) {
			ForEach(apps) { app in
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
		.listRowBackground(Color.clear)
	}

	private func importsSection(entries: [UnifiedImportEntry], groups: [SplitArtifactGroup]) -> some View {
		NBSection(.localized("Imports")) {
			UnifiedLibraryImportRows(entries: entries, groups: groups, controller: imports) {
				appNavigationPath.append(.splitArtifacts($0))
			}
		}
		.listSectionSeparator(.hidden)
		.listRowBackground(Color.clear)
		.id("libraryImports")
	}

	private var isConnectingTunnel: Bool {
		connection.isUpdating || connection.isAwaitingAutomaticConnection
	}

	private var showsDevicePlaceholder: Bool {
		installationMethod == 0 || !connection.hasPairingFile || connection.requiresInAppTunnelSetup
			|| failureDeviceStatus != nil
			|| (_showsCellularConnectionGuidance && _needsManualCellularRefresh)
			|| (!connection.isConnected && !isConnectingTunnel && !cellularAssist.isBusy
				&& updates.phase != .connecting && !isLoadingInstalledApps && !_showsCellularConnectionGuidance)
	}

	private var isLoadingInstalledApps: Bool {
		store.isLoading || (connection.isConnected && !store.hasLoadedApps && store.errorMessage == nil)
	}

	private var allAppsIsBusy: Bool {
		isConnectingTunnel || cellularAssist.isBusy || isLoadingInstalledApps
			|| updates.phase == .connecting || updates.phase == .checking
	}

	private var checkingForUpdatesStatus: String {
		.localized("Checking for Updates") + "…"
	}

	private var isCheckingForUpdatesStatus: Bool {
		allAppsSubtitle == checkingForUpdatesStatus
	}

	private var isConnectingTunnelStatus: Bool {
		isConnectingTunnel || cellularAssist.isBusy || (updates.phase == .connecting && !connection.isConnected)
	}

	private var showsAllAppsActivityIndicator: Bool {
		allAppsIsBusy && !isCheckingForUpdatesStatus && !isConnectingTunnelStatus
	}

	private var allAppsSubtitle: String {
		if isConnectingTunnel || cellularAssist.isBusy || (updates.phase == .connecting && !connection.isConnected) {
			return .localized("Connecting Tunnel") + "…"
		}
		if isLoadingInstalledApps || updates.phase == .connecting { return checkingForUpdatesStatus }
		if !connection.isConnected { return .localized("Tunnel Unavailable") }
		if store.errorMessage != nil { return .localized("Unable to Load Apps") }
		if updates.phase == .checking { return checkingForUpdatesStatus }
		if updates.noUpdatesUntil != nil { return .localized("No Updates Available") }
		return .localized("See all sideloaded apps")
	}

	private var libraryPageTitleStatus: String? {
		guard statusUnderPageTitle, installationMethod == 1, !showsDevicePlaceholder else { return nil }
		let status = allAppsSubtitle
		return status == .localized("See all sideloaded apps") ? nil : status
	}

	private var libraryPageTitleSubtitle: AnyView? {
		guard let status = libraryPageTitleStatus else { return nil }
		return AnyView(
			Text(status).lineLimit(1)
			.font(.caption)
			.foregroundStyle(.secondary)
			.fixedSize(horizontal: false, vertical: true)
		)
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
						allAppsSummary(subtitle: libraryPageTitleStatus == nil
							? allAppsSubtitle : String.localized("See all sideloaded apps"))
						ZStack {
							// Reserve a localized four-digit count even while the spinner
							// is visible. Digit changes cannot squeeze the subtitle.
							Text(max(9_999, store.apps.count), format: .number)
								.hidden().accessibilityHidden(true)
							Text(store.apps.count, format: .number)
								.foregroundStyle(.secondary)
								.opacity(showsAllAppsActivityIndicator && libraryPageTitleStatus == nil ? 0 : 1)
								.accessibilityHidden(showsAllAppsActivityIndicator && libraryPageTitleStatus == nil)
							if showsAllAppsActivityIndicator && libraryPageTitleStatus == nil {
								ProgressView()
							}
						}
						.font(.footnote)
						.monospacedDigit()
						.fixedSize(horizontal: true, vertical: false)
						.frame(minWidth: 20, minHeight: 20)
						.animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: allAppsIsBusy)
					}
				}
				.buttonStyle(.plain)
				.listRowSeparator(.hidden)
			}
		}
		.listRowBackground(Color.clear)
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

	private var libraryFocusState: [String] {
		[searchText, String(tabManager.isLibrarySearchPresented), tabManager.libraryFocusRequest?.uuidString ?? "", tabManager.selectedTab.rawValue,
		 String(describing: appNavigationPath), String(isRootListVisible), imports.infoApp?.id ?? "", String(imports.revision)]
	}

	private var libraryTitle: String {
		.localized("Library")
	}

	private struct DeviceStatus {
		enum Action { case pair, setupVPN, reconnect, tunnelingSettings }
		let title: String
		let description: String
		let icon: String
		var busy = false
		var action: Action?
		var buttonTitle: String?
	}

	private var failureDeviceStatus: DeviceStatus? {
		switch connection.diagnostic {
		case .providerMissing(let method):
			return DeviceStatus(title: method == .localDevVPN ? .localized("LocalDevVPN Missing") : .localized("Tunnel Extension Missing"), description: connection.diagnostic.localizedDescription, icon: "network.slash", action: .tunnelingSettings, buttonTitle: .localized("Settings"))
		case .invalidPairing:
			return DeviceStatus(title: .localized("Pairing File Invalid"), description: .localized("Replace the pairing file in Pairing File settings."), icon: "key.slash", action: .pair, buttonTitle: .localized("Pair"))
		case .error(let message):
			guard !connection.isAwaitingAutomaticConnection else { return nil }
			return DeviceStatus(title: .localized("Tunnel Unavailable"), description: message, icon: "network.slash", action: .reconnect, buttonTitle: .localized("Retry"))
		default: break
		}
		if connection.tunnelMethod == .inApp, case .failed(let message) = cellularAssist.state {
			return DeviceStatus(title: .localized("Cellular Assist Failed"), description: message, icon: "antenna.radiowaves.left.and.right", action: .tunnelingSettings, buttonTitle: .localized("Settings"))
		}
		return nil
	}

	private var deviceStatus: DeviceStatus {
		if !connection.hasPairingFile {
			return DeviceStatus(title: .localized("Pairing File Missing"), description: .localized("Add a pairing file to view sideloaded apps or spoof device location."), icon: "key.slash", action: .pair, buttonTitle: .localized("Pair"))
		} else if connection.requiresInAppTunnelSetup {
			return DeviceStatus(title: .localized("VPN Setup Required"), description: .localized("Set up Aether’s VPN profile to connect to your device."), icon: "network.badge.shield.half.filled", action: .setupVPN, buttonTitle: .localized("Set Up"))
		} else if let failure = failureDeviceStatus {
			return failure
		} else if _showsCellularConnectionGuidance && (store.apps.isEmpty || _needsManualCellularRefresh) {
			return DeviceStatus(title: _needsManualCellularRefresh ? .localized("Refresh Cellular Connection") : .localized("Connecting on Cellular"), description: _needsManualCellularRefresh ? .localized("Turn off Mobile Data or briefly enable Airplane Mode. Switch it back on once Aether connects.") : .localized("Aether is refreshing the cellular connection to reach your device."), icon: "antenna.radiowaves.left.and.right", busy: !_needsManualCellularRefresh, action: _needsManualCellularRefresh ? .reconnect : nil, buttonTitle: _needsManualCellularRefresh ? .localized("Retry") : nil)
		} else if isConnectingTunnel && store.apps.isEmpty {
			return DeviceStatus(title: .localized("Connecting Tunnel"), description: .localized("Aether is connecting so you can view sideloaded apps or spoof device location."), icon: "network")
		} else if !connection.isConnected {
			return DeviceStatus(title: .localized("Tunnel Unavailable"), description: .localized("Retry connecting or check Settings."), icon: "network.slash", action: .reconnect, buttonTitle: .localized("Retry"))

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
		} else if isConnectingTunnelStatus {
			TabPlaceholderView(
				title: .localized("Connecting Tunnel"),
				description: .localized("Aether is connecting so you can view sideloaded apps or spoof device location."),
				systemImage: "network"
			)
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
		case .tunnelingSettings: tabManager.openSettings(page: .tunnel)
		}
	}

	private var _showsCellularConnectionGuidance: Bool {
		guard installationMethod == 1, connection.physicalNetworkState == .cellularOnly else { return false }
		if connection.tunnelMethod == .inApp {
			return cellularAssist.isBusy || cellularAssist.isWaitingForManualRecovery
		}
		// Let LocalDevVPN open before showing the required network change.
		return connection.needsLocalDevVPNCellularRecovery
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
	@AppStorage("Aether.rowIconSize") private var rowIconSize: RowIconSize = .medium
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
