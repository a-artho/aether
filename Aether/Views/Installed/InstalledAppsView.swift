//
//  InstalledAppsView.swift
//  Aether
//

import IDeviceSwift
import NimbleViews
import SwiftUI
import UIKit

@MainActor
struct InstalledAppsView: View {
	@AppStorage("Aether.controlsInHeader") private var controlsInHeader = false
	@AppStorage("Aether.installationMethod") private var installationMethod = 0
	@AppStorage("Aether.serverMethod") private var serverMethod = 1
	@AppStorage("Aether.spoofing.simulationMayBeActive") private var isSpoofingActive = false
	@StateObject private var store: InstalledAppsStore
	@ObservedObject private var installationManager = AppInstallationManager.shared
	@Environment(\.scenePhase) private var scenePhase
	@ObservedObject private var localServer = LocalServerSetup.shared
	@ObservedObject private var connection = DeviceConnectionManager.shared
	@ObservedObject private var cellularAssist = CellularAssistManager.shared
	@ObservedObject private var tabManager = AppTabManager.shared
	@ObservedObject private var sourcesViewModel = SourcesViewModel.shared
	@FetchRequest(sortDescriptors: []) private var sources: FetchedResults<AltSource>
	@State private var appsWithUpdates = Set<String>()
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@State private var isSpoofingPresented = false
	@State private var isModeSwitchBlocked = false
	@State private var selectedAppBundleId: String?
	@State private var isRootListVisible = false
	@State private var visibleInstallRows = Set<UUID>()
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

	private enum DeviceSection: Identifiable {
		case installation, sideloaded
		var id: Self { self }
	}

	private struct DeviceLayout: Equatable {
		let sections: [DeviceSection]
		let cards: [UUID]
		let activeCard: UUID?
	}

	var body: some View {
		NBNavigationView(_installationMethodName, displayMode: .inline) {
			_deviceList
			.modifier(DeviceControlsBar(controls: _deviceControlsCard, isEnabled: !controlsInHeader))
			.task(id: installationMethod.description + ":" + serverMethod.description) {
				if installationMethod == 0 && serverMethod == 0 { await localServer.refresh() }
			}
			.onChange(of: scenePhase) { phase in
				if phase == .active, installationMethod == 0, serverMethod == 0 {
					Task { await localServer.refresh() }
				}
			}
			.task {
				guard loadsApps else { return }
				await store.load()
			}
			.task(id: updateIndicatorRequest) { await _loadUpdateIndicators() }
			.toolbar {
				ToolbarItem(placement: .topBarLeading) {
					Button {
						_toggleInstallationMode()
					} label: {
						Image(systemName: "arrow.left.arrow.right")
					}
					.accessibilityLabel(.localized("Switch Installation Mode"))
					.disabled(installationManager.hasPendingInstalls)
				}

				ToolbarItem(placement: .principal) {
					HStack(spacing: 6) {
						Circle()
							.fill(_installationMethodIsReady ? .green : .red)
							.frame(width: 8, height: 8)
						Text(_installationMethodName)
							.font(.headline)
					}
					.accessibilityElement(children: .combine)
					.accessibilityLabel(_installationMethodAccessibilityLabel)
				}

				ToolbarItemGroup(placement: .topBarTrailing) {
					if controlsInHeader { spoofingHeaderButton }
					Button {
						tabManager.openSettings()
					} label: {
						Image(systemName: "gear")
					}
					.accessibilityLabel(.localized("Settings"))
				}
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
	}

	private func _loadUpdateIndicators() async {
		guard loadsApps, !store.apps.isEmpty else { appsWithUpdates = []; return }
		await sourcesViewModel.ensureSourcesLoaded(Array(sources))
		let versions = store.apps.reduce(into: [String: String]()) { result, app in
			if let version = app.version { result[app.bundleIdentifier] = version }
		}
		let contexts = sources.compactMap { source -> SourceAppCatalogContext? in
			guard let repository = sourcesViewModel.repository(for: source) else { return nil }
			return SourceAppCatalogContext(sourceObjectURI: source.objectID.uriRepresentation().absoluteString,
				sourceURL: source.sourceURL, repository: repository, revision: sourcesViewModel.revision(for: source))
		}
		do {
			let matches = try await InstalledAppUpdateCatalog.shared.bundleIdentifiersWithUpdates(installedVersions: versions, contexts: contexts)
			try Task.checkCancellation()
			appsWithUpdates = matches
		} catch is CancellationError {
			// New installed versions or catalog revisions supersede this lookup.
		} catch { appsWithUpdates = [] }
	}

	private var _deviceList: some View {
		let cards = installationManager.installationCards
		let sections: [DeviceSection] = [
			cards.isEmpty ? nil : .installation,
			store.apps.isEmpty ? nil : .sideloaded
		].compactMap { $0 }
		let layout = DeviceLayout(sections: sections, cards: cards.map(\.id), activeCard: installationManager.currentRequest?.id)

		return ScrollViewReader { scrollProxy in
			List {
				ForEach(sections) { section in
					switch section {
					case .installation:
						_installationSection(cards: cards)
					case .sideloaded:
						_sideloadedSection
					}
				}
			}
			.listStyle(.plain)
			.onAppear { isRootListVisible = true }
			.onDisappear { isRootListVisible = false }
			.task(id: installationFocusState) {
				guard !Task.isCancelled, let request = tabManager.installationFocusRequest,
					tabManager.selectedTab == .installed, let firstCard = cards.first else { return }
				var transaction = Transaction()
				transaction.disablesAnimations = true
				if selectedAppBundleId != nil || isSpoofingPresented {
					withTransaction(transaction) {
						selectedAppBundleId = nil
						isSpoofingPresented = false
					}
					return
				}
				guard isRootListVisible else { return }
				withTransaction(transaction) { scrollProxy.scrollTo(firstCard.id, anchor: .top) }
				// Appearance confirms the lazy list has materialized the target.
				// Keep the request pending while navigation/layout catches up.
				if visibleInstallRows.contains(firstCard.id) {
					tabManager.consumeInstallationFocusRequest(request)
				}
			}
			.overlay {
				if cards.isEmpty && store.apps.isEmpty {
					_placeholderContent
						.transition(.opacity.animation(.easeInOut(duration: 0.2)))
				}
			}
			.animation(reduceMotion ? nil : .snappy, value: layout)
			.refreshable {
				guard loadsApps else { return }
				await store.refresh(force: true)
			}
			#if DEBUG
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Aether.openAppDetail"))) { notif in
				if let id = notif.object as? String {
					selectedAppBundleId = id
				} else {
					selectedAppBundleId = store.apps.first?.bundleIdentifier
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Aether.testScrollDevice"))) { _ in
				withAnimation {
					scrollProxy.scrollTo("com.example.app15", anchor: .top)
				}
			}
			#endif
		}
	}

	private func _installationSection(cards: [AppInstallationManager.InstallationRequest]) -> some View {
		NBSection(.localized("Installs"), secondary: cards.count.description) {
			ForEach(cards) { request in
				Group {
					if installationManager.currentRequest?.id == request.id, let vm = installationManager.viewModel {
						ActiveInstallationRow(app: request.app, viewModel: vm)
					} else {
						QueuedInstallationRow(request: request) {
							installationManager.cancelQueuedInstall(id: request.id)
						}
					}
				}
				.transition(.opacity)
				.listRowBackground(Color.clear)
				.id(request.id)
				.onAppear { visibleInstallRows.insert(request.id) }
				.onDisappear { visibleInstallRows.remove(request.id) }
			}
		}
		.listSectionSeparator(.hidden)
		.id("deviceInstalls")
	}

	private var _sideloadedSection: some View {
	case .sideloaded:
		NBSection(
			.localized("Sideloaded"),
			secondary: store.apps.count.description
		) {
			ForEach(store.apps) { app in
				NavigationLink(
					destination: InstalledAppDetailView(app: app, store: store),
					isActive: Binding(
						get: { selectedAppBundleId == app.bundleIdentifier },
						set: { isActive in
							if isActive {
								selectedAppBundleId = app.bundleIdentifier
							} else if selectedAppBundleId == app.bundleIdentifier {
								selectedAppBundleId = nil
							}
						}
					)
				) {
					InstalledAppCellView(app: app, loadsIcon: loadsIcons, hasUpdate: appsWithUpdates.contains(app.bundleIdentifier))
				}
				.buttonStyle(.plain)
				.id(app.id)
			}
		}
	}

	private var installationFocusState: [String] {
		[tabManager.installationFocusRequest?.uuidString ?? "",
		 tabManager.selectedTab.rawValue,
		 installationManager.installationCards.first?.id.uuidString ?? "",
		 selectedAppBundleId ?? "",
		 String(isSpoofingPresented), String(isRootListVisible),
		 String(installationManager.installationCards.first.map { visibleInstallRows.contains($0.id) } ?? false)]
	}

	private var updateIndicatorRequest: [String] {
		[String(sourcesViewModel.catalogRevision)] + store.apps.flatMap { [$0.bundleIdentifier, $0.version ?? ""] }
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
		.accessibilityHint(_canOpenSpoofing ? "Opens spoofing controls." : "Select iDevice mode and connect the tunnel to open spoofing controls.")
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
			.accessibilityHint(_canOpenSpoofing ? "Opens spoofing controls." : "Select iDevice mode and connect the tunnel to open spoofing controls.")
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
			return .init(text: .localized("iDevice required"), color: .secondary)
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
			return .init(text: .localized("iDevice required"), color: .secondary)
		}
		if isSpoofingActive {
			return .init(text: .localized("Active"), color: .green)
		}
		if _canOpenSpoofing {
			return .init(text: .localized("Ready"), color: .secondary)
		}
		return .init(text: .localized("Needs Tunnel"), color: .secondary)
	}

	private var _installationMethodName: String {
		installationMethod == 1 ? .localized("iDevice") : .localized("Server")
	}

	private var _installationMethodIsReady: Bool {
		if installationMethod == 1 {
			return connection.isConnected
		}

		if serverMethod == 1 {
			return true
		}

		return localServer.state == .ready
	}

	private var _installationMethodAccessibilityLabel: String {
		let status = _installationMethodIsReady
			? String.localized("Ready")
			: String.localized("Needs attention")
		return "\(_installationMethodName), \(status)"
	}

	@ViewBuilder
	private var _placeholderContent: some View {
		if installationMethod == 0 {
			TabPlaceholderView(
				title: .localized("Switch to iDevice"),
				description: .localized("Use iDevice mode to view sideloaded apps or spoof your device location."),
				systemImage: "iphone"
			) {
				Button {
					_switchToIDeviceMode()
				} label: {
					NBButton(.localized("Use iDevice"), style: .text)
				}
				.buttonStyle(.borderless)
				.disabled(installationManager.hasPendingInstalls)
			}
		} else if store.isLoading && store.apps.isEmpty {
			ProgressView()
				.padding(.vertical, 20)
		} else if !connection.hasPairingFile && store.apps.isEmpty {
			TabPlaceholderView(
				title: .localized("Pairing File Missing"),
				description: .localized("Add a pairing file to view sideloaded apps or spoof device location."),
				systemImage: "key.slash"
			) {
				Button {
					tabManager.openSettings(page: .pairingFile)
				} label: {
					NBButton(.localized("Pair"), style: .text)
				}
				.buttonStyle(.borderless)
			}
		} else if connection.requiresInAppTunnelSetup && store.apps.isEmpty {
			TabPlaceholderView(
				title: .localized("VPN Setup Required"),
				description: .localized("Set up Aether’s VPN profile to connect to your device."),
				systemImage: "network.badge.shield.half.filled"
			) {
				Button {
					connection.setUpInAppTunnel()
				} label: {
					NBButton(.localized("Set Up"), style: .text)
				}
				.buttonStyle(.borderless)
			}
		} else if _showsCellularConnectionGuidance && store.apps.isEmpty {
			TabPlaceholderView(
				title: _needsManualCellularRefresh
					? .localized("Refresh Cellular Connection")
					: .localized("Connecting on Cellular"),
				description: _needsManualCellularRefresh
					? .localized("Turn off Mobile Data or briefly enable Airplane Mode. Switch it back on once Aether connects.")
					: .localized("Aether is refreshing the cellular connection to reach your device."),
				systemImage: "antenna.radiowaves.left.and.right"
			) {
				ProgressView()
					.controlSize(.small)
			}
		} else if connection.isUpdating && store.apps.isEmpty {
			TabPlaceholderView(
				title: .localized("Connecting Tunnel"),
				description: .localized("Aether is connecting so you can view sideloaded apps or spoof device location."),
				systemImage: "network"
			) {
				ProgressView()
					.controlSize(.small)
			}
		} else if !connection.isConnected && store.apps.isEmpty {
			TabPlaceholderView(
				title: .localized("Tunnel Unavailable"),
				description: .localized("Reconnect the tunnel to view sideloaded apps or spoof device location."),
				systemImage: "network.slash"
			) {
				Button {
					connection.reconnectForIDeviceMode()
				} label: {
					NBButton(.localized("Retry"), style: .text)
				}
				.buttonStyle(.borderless)
			}
		} else if let errorMessage = store.errorMessage, store.apps.isEmpty {
			TabPlaceholderView(
				title: .localized("Unable to Load Installed Apps"),
				description: errorMessage,
				systemImage: "iphone.slash"
			) {
				Button {
					Task { await store.refresh(force: true) }
				} label: {
					NBButton(.localized("Retry"), style: .text)
				}
				.buttonStyle(.borderless)
			}
		} else {
			TabPlaceholderView(
				title: .localized("No Sideloaded Apps"),
				description: .localized("Sideloaded apps will appear here. You can spoof device location above."),
				systemImage: "square.stack.3d.up.slash"
			)
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

private struct InstalledAppCellView: View {
	@Environment(\.horizontalSizeClass) private var horizontalSizeClass
	let app: InstalledApp
	let loadsIcon: Bool
	let hasUpdate: Bool
	@AppStorage("Aether.userTintColor") private var themeTint = "#848ef9"

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
			if hasUpdate {
				Circle()
					.fill(Color(hex: themeTint))
					.frame(width: 8, height: 8)
					.accessibilityHidden(true)
			}
		}
		.padding(horizontalSizeClass == .compact ? 0 : 12)
		.background {
			if horizontalSizeClass != .compact {
				RoundedRectangle(cornerRadius: 18, style: .continuous)
					.fill(Color(.quaternarySystemFill))
			}
		}
		.contentShape(Rectangle())
		.accessibilityHint(hasUpdate ? .localized("Update Available") : "")
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
		if #available(iOS 26, *) {
			content.safeAreaBar(edge: .top, spacing: 0) { bar }
		} else {
			content.safeAreaInset(edge: .top, spacing: 0) { bar }
		}
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
		if #available(iOS 26, *), liquidGlassTiles {
			button.buttonStyle(.plain)
		} else {
			button.buttonStyle(_HomeCardButtonStyle { HapticManager.shared.impact() })
		}
	}

	private var button: some View {
		Button {
			if #available(iOS 26, *), liquidGlassTiles { HapticManager.shared.impact() }
			action()
		} label: {
			HStack(spacing: 8) {
				Image(systemName: systemImage)
					.font(.system(size: 17, weight: .semibold))
					.foregroundStyle(isActive ? activeColor : Color.secondary.opacity(isDisabled ? 0.55 : 1))
					.frame(width: 24, height: 24)

				VStack(alignment: .leading, spacing: 2) {
					Text(title)
						.font(.subheadline.weight(.semibold))
						.foregroundStyle(.primary)
						.lineLimit(1)

					Text(subtitle)
						.font(.caption2.weight(.medium))
						.foregroundStyle(.secondary)
						.lineLimit(1)
						.minimumScaleFactor(0.8)
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
		if #available(iOS 26, *), liquidGlassTiles {
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
		if #available(iOS 26, *), liquidGlassTiles {
			content.glassEffect(.regular.interactive(!isDisabled), in: .rect(cornerRadius: 15))
		} else {
			content.background(Color(uiColor: .secondarySystemGroupedBackground),
				in: RoundedRectangle(cornerRadius: 15, style: .continuous))
		}
	}
}

private struct _HomeCardButtonStyle: ButtonStyle {
	let onPress: () -> Void

	func makeBody(configuration: Configuration) -> some View {
		_HomeCardButtonStyleBody(configuration: configuration, onPress: onPress)
	}
}

private struct _HomeCardButtonStyleBody: View {
	let configuration: _HomeCardButtonStyle.Configuration
	let onPress: () -> Void
	@State private var keepsPressedAppearance = false
	@State private var releaseTask: Task<Void, Never>?

	private var isPressed: Bool {
		configuration.isPressed || keepsPressedAppearance
	}

	var body: some View {
		configuration.label
			.scaleEffect(isPressed ? 0.965 : 1.0)
			.opacity(isPressed ? 0.84 : 1.0)
			.overlay {
				RoundedRectangle(cornerRadius: 15, style: .continuous)
					.fill(.black.opacity(isPressed ? 0.08 : 0))
			}
			.animation(.spring(response: 0.2, dampingFraction: 0.82), value: isPressed)
			.onChange(of: configuration.isPressed) { pressed in
				if pressed {
					releaseTask?.cancel()
					keepsPressedAppearance = true
					onPress()
				} else {
					releaseTask?.cancel()
					releaseTask = Task { @MainActor in
						try? await Task.sleep(for: .milliseconds(110))
						guard !Task.isCancelled else { return }
						keepsPressedAppearance = false
					}
				}
			}
			.onDisappear {
				releaseTask?.cancel()
			}
	}
}

#Preview("Installed Apps") {
	InstalledAppsView(
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
	InstalledAppsView(store: InstalledAppsStore(), loadsApps: false, loadsIcons: false)
}
