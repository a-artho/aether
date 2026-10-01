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
	@AppStorage("Aether.installationMethod") private var installationMethod = 0
	@AppStorage("Aether.serverMethod") private var serverMethod = 1
	@AppStorage("Aether.spoofing.simulationMayBeActive") private var isSpoofingActive = false
	@StateObject private var store: InstalledAppsStore
	@ObservedObject private var installationManager = AppInstallationManager.shared
	@ObservedObject private var connection = DeviceConnectionManager.shared
	@ObservedObject private var cellularAssist = CellularAssistManager.shared
	@ObservedObject private var tabManager = AppTabManager.shared
	@State private var topCardMaxY: CGFloat = 160
	@State private var isSpoofingPresented = false
	@State private var isModeSwitchBlocked = false
	@State private var selectedAppBundleId: String?
	private let loadsApps: Bool
	private let loadsIcons: Bool

	init() {
		_store = StateObject(wrappedValue: InstalledAppsStore())
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

	var body: some View {
		NBNavigationView(_installationMethodName, displayMode: .inline) {
			ZStack(alignment: .top) {
				ScrollViewReader { scrollProxy in
					List {
						Section {
							_deviceControlsCard
								.listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
								.listRowBackground(Color.clear)
								.listRowSeparator(.hidden)
								.background {
									if installationManager.activeApp == nil {
										GeometryReader { geo in
											Color.clear.preference(
												key: CardBottomPreferenceKey.self,
												value: geo.frame(in: .named("DeviceTabRoot")).maxY
											)
										}
									}
								}
						}
						.listSectionSeparator(.hidden)

						if let activeApp = installationManager.activeApp, let vm = installationManager.viewModel {
							Section {
								ActiveInstallationHeroCard(app: activeApp, viewModel: vm)
									.listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
									.listRowBackground(Color.clear)
									.listRowSeparator(.hidden)
									.background {
										GeometryReader { geo in
											Color.clear.preference(
												key: CardBottomPreferenceKey.self,
												value: geo.frame(in: .named("DeviceTabRoot")).maxY
											)
										}
									}
							}
							.listSectionSeparator(.hidden)
						}

						if !store.apps.isEmpty {
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
										InstalledAppCellView(app: app, loadsIcon: loadsIcons)
									}
									.buttonStyle(.plain)
									.id(app.id)
								}
							}
						}
					}
					.listStyle(.plain)
					.refreshable {
						guard loadsApps else { return }
						await store.refresh()
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

				if store.apps.isEmpty {
					GeometryReader { rootGeo in
						let cardBottom = topCardMaxY
						// Account for the floating tab bar clearance (tab bar height + safe area insets)
						let bottomEdge = max(cardBottom, rootGeo.size.height - rootGeo.safeAreaInsets.bottom)
						let availableHeight = bottomEdge - cardBottom
						let centerY = cardBottom + (availableHeight / 2)

						_placeholderContent
							.frame(width: rootGeo.size.width)
							.position(x: rootGeo.size.width / 2, y: centerY)
							.transition(.opacity.animation(.easeInOut(duration: 0.2)))
					}
				}
			}
			.coordinateSpace(name: "DeviceTabRoot")
			.onPreferenceChange(CardBottomPreferenceKey.self) { maxY in
				if maxY > 0 {
					topCardMaxY = maxY
				}
			}
			.animation(.spring(response: 0.35, dampingFraction: 0.85), value: installationManager.activeApp != nil)
			.task {
				guard loadsApps else { return }
				await store.load()
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Aether.installedAppsRefresh"))) { _ in
				Task {
					guard loadsApps, connection.isConnected else { return }
					await store.refresh()
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: .heartbeat)) { _ in
				Task {
					await connection.reconcile()
				}
			}
			.onChange(of: connection.isConnected) { isConnected in
				guard loadsApps else { return }
				Task {
					if isConnected {
						await store.refresh()
					} else {
						store.clear()
					}
				}
			}
			.toolbar {
				ToolbarItem(placement: .topBarLeading) {
					Button {
						_toggleInstallationMode()
					} label: {
						Image(systemName: "arrow.left.arrow.right")
					}
					.accessibilityLabel(.localized("Switch Installation Mode"))
					.disabled(installationManager.isInstalling)
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

				ToolbarItem(placement: .topBarTrailing) {
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

	private var _deviceControlsCard: some View {
		HStack(spacing: 12) {
			_homeAccessoryTile(
				title: .localized("Tunnel"),
				subtitle: _tunnelStatus.text,
				systemImage: "network",
				isActive: connection.isConnected,
				activeColor: .green,
				action: {
					if !connection.hasPairingFile {
						tabManager.openSettings(page: .pairingFile)
			} else if connection.requiresInAppTunnelSetup {
				connection.setUpInAppTunnel()
			} else if !connection.isConnected {
				connection.reconnectForIDeviceMode()
					} else {
						tabManager.openSettings(page: .tunnel)
					}
				}
			)
			.accessibilityLabel("Tunnel, \(_tunnelStatus.text)")
			.accessibilityHint(!connection.hasPairingFile ? "Opens pairing settings." : (!connection.isConnected ? "Reconnects the tunnel." : "Opens tunnel settings."))

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
		Button(action: action) {
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
			.background {
				RoundedRectangle(cornerRadius: 15, style: .continuous)
					.fill(Color(uiColor: .secondarySystemGroupedBackground))
			}
		}
		.buttonStyle(_HomeCardButtonStyle {
			HapticManager.shared.impact()
		})
		.disabled(isDisabled)
		.opacity(isDisabled ? 0.6 : 1.0)
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

	private var _installationMethodName: String {
		installationMethod == 1 ? .localized("Local") : .localized("Server")
	}

	private var _installationMethodIsReady: Bool {
		if installationMethod == 1 {
			return connection.isConnected
		}

		if serverMethod == 1 {
			return true
		}

		return ServerInstaller.getUrl("server", ext: "crt") != nil
			&& ServerInstaller.getUrl("server", ext: "pem") != nil
			&& ServerInstaller.getUrl("commonName", ext: "txt") != nil
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
				title: .localized("Switch to Local"),
				description: .localized("Use Local mode to view sideloaded apps or spoof your device location."),
				systemImage: "iphone"
			) {
				Button {
					_switchToIDeviceMode()
				} label: {
					NBButton(.localized("Use Local"), style: .text)
				}
				.buttonStyle(.borderless)
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
					Task { await store.refresh() }
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

	var body: some View {
		HStack(spacing: 14) {
			InstalledAppIconView(
				bundleIdentifier: app.bundleIdentifier,
				cacheVersion: app.iconCacheVersion,
				loadsIcon: loadsIcon
			)

			VStack(alignment: .leading, spacing: 2) {
				Text(app.name)
					.font(.headline)
					.lineLimit(1)
				if let version = app.version ?? app.build {
					Text(version)
						.font(.subheadline)
						.foregroundStyle(.secondary)
				}
				Text(app.bundleIdentifier)
					.font(.caption)
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}
			.frame(maxWidth: .infinity, alignment: .leading)

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
			guard loadsIcon else { return }
			let loaded = try? await InstallationAppProxy.getAppIconCached(
				for: bundleIdentifier,
				cacheVersion: cacheVersion
			)
			withAnimation(.easeIn(duration: 0.15)) {
				image = loaded
			}
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

private struct CardBottomPreferenceKey: PreferenceKey {
	static var defaultValue: CGFloat = 160
	static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
		let next = nextValue()
		if next > 0 {
			value = next
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
