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
	@AppStorage("Aether.settingsPlacement") private var settingsPlacement: SettingsPlacement = .header
	@StateObject private var imports = UnifiedImportsController()
	@AppStorage("Aether.controlsInHeader") private var controlsInHeader = false
	@AppStorage("Aether.installationMethod") private var installationMethod = 0
	@AppStorage("Aether.serverMethod") private var serverMethod = 1
	@AppStorage("Aether.spoofing.simulationMayBeActive") private var isSpoofingActive = false
	@StateObject private var store: InstalledAppsStore
	@ObservedObject private var installationManager = AppInstallationManager.shared
	@ObservedObject private var connection = DeviceConnectionManager.shared
	@ObservedObject private var cellularAssist = CellularAssistManager.shared
	@ObservedObject private var tabManager = AppTabManager.shared
	@ObservedObject private var sourcesViewModel = SourcesViewModel.shared
	@FetchRequest(sortDescriptors: []) private var sources: FetchedResults<AltSource>
	@State private var updateContexts: [String: [SourceAppCatalogContext]] = [:]
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@State private var searchText = ""
	@State private var searchFocused = false
	@State private var toolbarWidth: CGFloat = 320
	@State private var isSpoofingPresented = false
	@State private var isModeSwitchBlocked = false
	@State private var appNavigationPath: [InstalledAppsRoute] = []
	@State private var isRootListVisible = false
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
			: !showsDevicePlaceholder && !sideloadedApps.isEmpty
		let appsWithUpdates = sideloadedApps.filter { updateContexts[$0.bundleIdentifier]?.isEmpty == false }
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
							.environment(\.editMode, $imports.editMode)
							.id("libraryImports")

						}
					}
				}
				.navigationTitle(libraryTitle)
				.navigationBarTitleDisplayMode(.inline)
				.navigationDestination(for: InstalledAppsRoute.self) { route in
					switch route {
					case .allApps:
						AllInstalledAppsView(store: store, loadsIcons: loadsIcons,
							initialSearch: searchText, placeholder: _placeholderContent)
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
					if !appNavigationPath.isEmpty || isSpoofingPresented || imports.infoApp != nil {
						withTransaction(transaction) {
							appNavigationPath.removeAll()
							isSpoofingPresented = false
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
					if !appNavigationPath.isEmpty || isSpoofingPresented || imports.infoApp != nil {
						withTransaction(transaction) {
							appNavigationPath.removeAll()
							isSpoofingPresented = false
							imports.infoApp = nil
						}
						return
					}
					guard isRootListVisible else { return }
					withTransaction(transaction) {
						imports.finishSelection()
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
				.animation(reduceMotion ? nil : .snappy, value: layout)
				.modifier(UnifiedImportsDataSource(controller: imports))
				.refreshable {
					guard loadsApps else { return }
					await store.refresh(force: true)
				}
			}
			.modifier(DeviceControlsBar(controls: _deviceControlsCard, isEnabled: !controlsInHeader))
			.task {
				guard loadsApps else { return }
				await store.load()
			}
			.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { toolbarWidth = $0 }
			.modifier(SearchToolbarModifier(
				text: $searchText, isPresented: $tabManager.isLibrarySearchPresented,
				focus: $searchFocused, title: libraryTitle, width: toolbarWidth,
				enabled: !imports.editMode.isEditing, isScreenActive: isRootListVisible && appNavigationPath.isEmpty,
				hasTitleMenu: false,
				secondaryAction: { imports.importing = true },
				secondaryURLAction: { imports.urlText = ""; imports.importingURL = true }
			) { EmptyView() })
			.toolbar { libraryToolbar }
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
			.sheet(isPresented: $isSpoofingPresented) {
				SpoofingEntryView()
			}
			.alert(.localized("Stop Spoofing First"), isPresented: $isModeSwitchBlocked) {
				Button(.localized("Open Spoofing")) {
					isSpoofingPresented = true
				}
				Button(.localized("Cancel"), role: .cancel) {}
			} message: {
				Text(.localized("Stop the simulated location before switching to Server mode."))
			}
		}
		.task(id: updateRequest) {
			guard loadsApps, installationMethod == 1, !store.apps.isEmpty else {
				updateContexts = [:]
				_ = try? await InstalledAppUpdateCatalog.shared.updates(installedVersions: [:], contexts: [])
				return
			}
			await sourcesViewModel.ensureSourcesLoaded(Array(sources))
			let versions = store.apps.reduce(into: [String: String]()) { values, app in
				if let version = app.version { values[app.bundleIdentifier] = version }
			}
			let contexts = sources.compactMap { source -> SourceAppCatalogContext? in
				guard let repository = sourcesViewModel.repository(for: source) else { return nil }
				return SourceAppCatalogContext(sourceObjectURI: source.objectID.uriRepresentation().absoluteString,
					sourceURL: source.sourceURL, repository: repository, revision: sourcesViewModel.revision(for: source))
			}
			do {
				let matches = try await InstalledAppUpdateCatalog.shared.updates(installedVersions: versions, contexts: contexts)
				try Task.checkCancellation()
				updateContexts = matches
			} catch is CancellationError {} catch { updateContexts = [:] }
		}
	}

	@ToolbarContentBuilder private var libraryToolbar: some ToolbarContent {
		ToolbarItemGroup(placement: .topBarLeading) {
			if imports.editMode.isEditing {
				Button(String.localized("Done")) { imports.finishSelection() }
			} else if !tabManager.isLibrarySearchPresented {
				if settingsPlacement == .header { settingsButton }
			}
		}

		ToolbarItemGroup(placement: .topBarTrailing) {
			if imports.editMode.isEditing {
				Button(role: .destructive) { imports.deleteSelected() } label: { Image(systemName: "trash") }
					.disabled(imports.selectedRows.isEmpty)
					.accessibilityLabel(String.localized("Delete"))
			} else if !tabManager.isLibrarySearchPresented {
				if controlsInHeader { spoofingHeaderButton }
			}
		}
	}

	private var showsDevicePlaceholder: Bool {
		installationMethod == 0 || store.apps.isEmpty
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
					allAppsSummary(subtitle: String.localized("See all sideloaded apps"))
				}
				.buttonStyle(.plain)
				.listRowSeparator(.hidden)
			}
		}
	}

	private func allAppsSummary(subtitle: String) -> some View {
		HStack(spacing: 18) {
			Image(systemName: "square.stack.3d.up.fill")
				.font(.system(size: 30, weight: .regular))
				.symbolRenderingMode(.hierarchical)
				.foregroundStyle(.secondary)
				.frame(width: 50, height: 50)
			NBTitleWithSubtitleView(title: String.localized("All Apps"), subtitle: subtitle)
		}
	}

	private var settingsButton: some View {
		Menu("Settings", systemImage: "gearshape") {
			Button(String.localized("Switch Installation Mode"), systemImage: "arrow.left.arrow.right", action: _toggleInstallationMode)
				.disabled(installationManager.hasPendingInstalls)
			Divider()
			Button(String.localized("Select"), systemImage: "checkmark.circle") {
				imports.select()
			}
			.disabled(!imports.hasRows)
			Button(String.localized("Delete All"), systemImage: "trash", role: .destructive) {
				imports.confirmingDeleteAll = true
			}
			.disabled(!imports.hasRows)
		} primaryAction: {
			tabManager.openSettings()
		}
		.menuIndicator(.hidden)
		.accessibilityLabel(String.localized("Settings"))
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
		 String(isSpoofingPresented), imports.infoApp?.id ?? "", String(isRootListVisible), String(imports.revision),
		 String(installationManager.installationCards.first.map { operationIsVisible($0.id) } ?? false)]
	}

	private var libraryFocusState: [String] {
		[searchText, String(tabManager.isLibrarySearchPresented), tabManager.libraryFocusRequest?.uuidString ?? "", tabManager.selectedTab.rawValue,
		 String(describing: appNavigationPath), String(isRootListVisible), String(isSpoofingPresented), imports.infoApp?.id ?? "", String(imports.revision)]
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
		[String(installationMethod), String(sourcesViewModel.catalogRevision)]
			+ store.apps.flatMap { [$0.bundleIdentifier, $0.version ?? ""] }
			+ sources.flatMap { [$0.objectID.uriRepresentation().absoluteString, $0.sourceURL?.absoluteString ?? ""] }
	}

	private var spoofingHeaderButton: some View {
		Button {
			HapticManager.shared.impact()
			isSpoofingPresented = true
		} label: {
			Image(systemName: "location.fill")
				.foregroundStyle(isSpoofingActive ? Color.green : Color.secondary.opacity(_canOpenSpoofing ? 1 : 0.55))
		}
		.disabled(!_canOpenSpoofing)
		.opacity((_canOpenSpoofing ? 1 : 0.6) * (installationMethod == 1 ? 1 : 0.45))
		.accessibilityLabel("Spoofing, \(_spoofingStatus.text)")
		.accessibilityHint(_canOpenSpoofing ? "Opens spoofing controls." : "Select Local mode and connect the tunnel to open spoofing controls.")
	}

	private var _deviceControlsCard: some View {
		DeviceAccessoryTileGroup {
			_homeAccessoryTile(
				title: .localized("Tunnel"),
				subtitle: _tunnelStatus.text,
				systemImage: "network",
				isActive: connection.isConnected,
				activeColor: .green,
				action: {
					tabManager.openSettings(page: connection.hasPairingFile ? .tunnel : .pairingFile)
				}
			)
			.accessibilityLabel("Tunnel, \(_tunnelStatus.text)")
			.accessibilityHint(connection.hasPairingFile ? "Opens tunnel settings." : "Opens pairing settings.")

			_homeAccessoryTile(
				title: .localized("Spoofing"),
				subtitle: _spoofingStatus.text,
				systemImage: "location.fill",
				isActive: isSpoofingActive,
				activeColor: .green,
				isDisabled: !_canOpenSpoofing,
				action: {
					isSpoofingPresented = true
				}
			)
			.accessibilityLabel("Spoofing, \(_spoofingStatus.text)")
			.accessibilityHint(_canOpenSpoofing ? "Opens spoofing controls." : "Select Local mode and connect the tunnel to open spoofing controls.")
		}
		.opacity(installationMethod == 1 ? 1 : 0.45)
	}

	@ViewBuilder
	private func _homeAccessoryTile(
		title: String,
		subtitle: String,
		systemImage: String,
		isActive: Bool,
		activeColor: Color,
		isDisabled: Bool = false,
		action: @escaping () -> Void
	) -> some View {
		DeviceAccessoryTile(title: title, subtitle: subtitle, systemImage: systemImage,
			isActive: isActive, activeColor: activeColor, isDisabled: isDisabled, action: action)
	}

	private var _canOpenSpoofing: Bool {
		installationMethod == 1 && connection.isConnected && !connection.isUpdating
	}

	private var _tunnelStatus: _DeviceControlStatus {
		guard installationMethod == 1 else {
			return .init(text: .localized("Local required"), color: .secondary)
		}
		if connection.isUpdating {
			return .init(text: .localized("Connecting"), color: .orange)
		}
		if connection.isConnected {
			return .init(text: .localized("Connected"), color: .green)
		}
		if !connection.hasPairingFile {
			return .init(text: .localized("Needs Pairing"), color: .red)
		}
		if connection.requiresInAppTunnelSetup {
			return .init(text: .localized("Setup Required"), color: .orange)
		}
		return .init(text: .localized("Unavailable"), color: .red)
	}

	private var _spoofingStatus: _DeviceControlStatus {
		guard installationMethod == 1 else {
			return .init(text: .localized("Local required"), color: .secondary)
		}
		if isSpoofingActive {
			return .init(text: .localized("Active"), color: .green)
		}
		if _canOpenSpoofing {
			return .init(text: .localized("Ready"), color: .secondary)
		}
		return .init(text: .localized("Needs Tunnel"), color: .secondary)
	}

	private var libraryTitle: String {
		.localized("Library")
	}

	private struct DeviceStatus {
		enum Action { case pair, setupVPN, reconnect, reload }
		let title: String
		let description: String
		let icon: String
		var busy = false
		var action: Action?
		var buttonTitle: String?
	}

	private var deviceStatus: DeviceStatus {
		if store.isLoading && store.apps.isEmpty {
			return DeviceStatus(title: .localized("Loading Installed Apps"), description: "", icon: "iphone", busy: true)
		} else if !connection.hasPairingFile && store.apps.isEmpty {
			return DeviceStatus(title: .localized("Pairing File Missing"), description: .localized("Add a pairing file to view sideloaded apps or spoof device location."), icon: "key.slash", action: .pair, buttonTitle: .localized("Pair"))
		} else if connection.requiresInAppTunnelSetup && store.apps.isEmpty {
			return DeviceStatus(title: .localized("VPN Setup Required"), description: .localized("Set up Aether’s VPN profile to connect to your device."), icon: "network.badge.shield.half.filled", action: .setupVPN, buttonTitle: .localized("Set Up"))
		} else if _showsCellularConnectionGuidance && store.apps.isEmpty {
			return DeviceStatus(title: _needsManualCellularRefresh ? .localized("Refresh Cellular Connection") : .localized("Connecting on Cellular"), description: _needsManualCellularRefresh ? .localized("Turn off Mobile Data or briefly enable Airplane Mode. Switch it back on once Aether connects.") : .localized("Aether is refreshing the cellular connection to reach your device."), icon: "antenna.radiowaves.left.and.right", busy: true)
		} else if connection.isUpdating && store.apps.isEmpty {
			return DeviceStatus(title: .localized("Connecting Tunnel"), description: .localized("Aether is connecting so you can view sideloaded apps or spoof device location."), icon: "network", busy: true)
		} else if !connection.isConnected && store.apps.isEmpty {
			return DeviceStatus(title: .localized("Tunnel Unavailable"), description: .localized("Reconnect the tunnel to view sideloaded apps or spoof device location."), icon: "network.slash", action: .reconnect, buttonTitle: .localized("Retry"))
		} else if let error = store.errorMessage, store.apps.isEmpty {
			return DeviceStatus(title: .localized("Unable to Load Installed Apps"), description: error, icon: "iphone.slash", action: .reload, buttonTitle: .localized("Retry"))
		} else {
			return DeviceStatus(title: .localized("No Sideloaded Apps"), description: .localized("Sideloaded apps will appear here. You can spoof device location above."), icon: "square.stack.3d.up.slash")
		}
	}

	@ViewBuilder private var _placeholderContent: some View {
		let status = deviceStatus
		if store.isLoading && store.apps.isEmpty && installationMethod != 0 {
			ProgressView().padding(.vertical, 20)
		} else {
			TabPlaceholderView(title: status.title, description: status.description, systemImage: status.icon) {
				deviceStatusAction(status)
			}
		}
	}

	private var compactDeviceStatus: some View {
		let status = deviceStatus
		return VStack(spacing: 8) {
			HStack(spacing: 6) {
				Image(systemName: status.icon)
					.nbFont(.subheadline).foregroundStyle(.secondary)
					.accessibilityHidden(true)
				Text(status.title)
					.nbFont(.subheadline).foregroundStyle(.secondary)
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
		case .reload: Task { await store.refresh(force: true) }
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

	private func _toggleInstallationMode() {
		if installationMethod == 1 {
			guard !isSpoofingActive else {
				isModeSwitchBlocked = true
				return
			}
			guard connection.setInstallationMode(0) else {
				isModeSwitchBlocked = true
				return
			}
		} else {
			_ = connection.setInstallationMode(1)
		}
		HapticManager.shared.selection()
	}

	private func _switchToIDeviceMode() {
		guard connection.setInstallationMode(1) else { return }
		HapticManager.shared.selection()
	}

	private struct _DeviceControlStatus {
		let text: String
		let color: Color
	}

}

struct InstalledAppCellView: View {
	@Environment(\.horizontalSizeClass) private var horizontalSizeClass
	let app: InstalledApp
	let loadsIcon: Bool

	var body: some View {
		HStack(spacing: 18) {
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
	var size: CGFloat = 50
	@State private var image: UIImage?

	var body: some View {
		Group {
			if let image {
				Image(uiImage: image).appIconStyle(size: size)
			} else {
				Image("App_Unknown").appIconStyle(size: size)
			}
		}
		.animation(.easeIn(duration: 0.15), value: image != nil)
		.task(id: bundleIdentifier + "|" + cacheVersion) {
			await loadIcon()
		}
	}

	private func loadIcon() async {
		guard loadsIcon, !Task.isCancelled else { return }
		let loaded = try? await InstallationAppProxy.getAppIconCached(
			for: bundleIdentifier,
			cacheVersion: cacheVersion
		)
		guard !Task.isCancelled else { return }
		withAnimation(.easeIn(duration: 0.15)) { image = loaded }
	}
}

struct DeviceControlsBar<Controls: View>: ViewModifier {
	let controls: Controls
	var isEnabled = true

	func body(content: Content) -> some View {
		content.safeAreaBar(edge: .top, spacing: 0) { bar }
	}

	@ViewBuilder
	private var bar: some View {
		if isEnabled {
			controls
				.padding(.horizontal, 16)
				.padding(.vertical, 8)
		}
	}
}

struct DeviceAccessoryTile: View {
	@AppStorage("Aether.liquidGlassTiles") private var liquidGlassTiles = true
	let title: String
	let subtitle: String
	let systemImage: String
	var isActive = false
	var activeColor: Color = .green
	var isDisabled = false
	let action: () -> Void

	var body: some View {
		if liquidGlassTiles {
			button.buttonStyle(.plain)
		} else {
			button.buttonStyle(.borderless)
		}
	}

	private var button: some View {
		Button {
			HapticManager.shared.impact()
			action()
		} label: {
			HStack(spacing: 8) {
				Image(systemName: systemImage)
					.font(.system(size: 17, weight: .semibold))
					.foregroundStyle(isActive ? activeColor : Color.secondary.opacity(isDisabled ? 0.55 : 1))
					.frame(width: 24, height: 24)

				VStack(alignment: .leading, spacing: 2) {
					Text(title)
						.nbFont(.subheadline, weight: .semibold)
						.foregroundStyle(.primary)
						.fixedSize(horizontal: false, vertical: true)

					Text(subtitle)
						.font(.caption2.weight(.medium))
						.foregroundStyle(.secondary)
						.fixedSize(horizontal: false, vertical: true)
				}

				Spacer(minLength: 0)
			}
			.padding(.horizontal, 10)
			.padding(.vertical, 8)
			.frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
			.modifier(DeviceAccessoryTileSurface(isDisabled: isDisabled, liquidGlassTiles: liquidGlassTiles))
			.contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
		}
		.disabled(isDisabled)
		.opacity(isDisabled ? 0.6 : 1.0)
	}
}

struct DeviceAccessoryTileGroup<Content: View>: View {
	@AppStorage("Aether.liquidGlassTiles") private var liquidGlassTiles = true
	@ViewBuilder var content: Content

	var body: some View {
		if liquidGlassTiles {
			GlassEffectContainer(spacing: 8) {
				HStack(spacing: 12) { content }
			}
		} else {
			HStack(spacing: 12) { content }
		}
	}
}

private struct DeviceAccessoryTileSurface: ViewModifier {
	let isDisabled: Bool
	let liquidGlassTiles: Bool

	func body(content: Content) -> some View {
		if liquidGlassTiles {
			content.glassEffect(.regular.interactive(!isDisabled), in: .rect(cornerRadius: 15))
		} else {
			content.background(Color(uiColor: .secondarySystemGroupedBackground),
				in: RoundedRectangle(cornerRadius: 15, style: .continuous))
		}
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
