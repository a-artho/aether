//
//  InstalledAppsView.swift
//  Feather
//

import IDeviceSwift
import NimbleViews
import SwiftUI

@MainActor
struct InstalledAppsView: View {
	@StateObject private var store: InstalledAppsStore
	@ObservedObject private var installationManager = AppInstallationManager.shared
	@StateObject private var localDevVPN = LocalDevVPNConnectionMonitor()
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
		NBNavigationView(.localized("Device"), displayMode: .inline) {
			VStack(spacing: 0) {
				DeviceConnectionStatusCard(connection: localDevVPN)
					.padding(.horizontal)
					.padding(.top, 8)
					.padding(.bottom, 6)

				if let activeApp = installationManager.activeApp, let vm = installationManager.viewModel {
					ActiveInstallationHeroCard(app: activeApp, viewModel: vm)
						.padding(.horizontal)
						.padding(.top, 8)
						.padding(.bottom, 6)
						.transition(.move(edge: .top).combined(with: .opacity))
				}

				NBListAdaptable {
					NBSection(.localized("Sideloaded")) {
						ForEach(store.apps) { app in
							InstalledAppCellView(app: app, loadsIcon: loadsIcons)
						}
					}
				}
				.refreshable {
					guard loadsApps else { return }
					await store.refresh()
				}
				.overlay {
					if store.isLoading && store.apps.isEmpty {
						ProgressView()
					} else if !localDevVPN.hasPairingFile && store.apps.isEmpty {
						_statusView(
							title: .localized("Pairing File Missing"),
							description: .localized("Import a pairing file in Installation settings, then turn on LocalDevVPN to view sideloaded apps on this device."),
							systemImage: "key.slash"
						)
					} else if !localDevVPN.isConnected && store.apps.isEmpty {
						_statusView(
							title: .localized("LocalDevVPN Is Off"),
							description: .localized("Turn it on to view sideloaded apps on this device."),
							systemImage: "network.slash"
						)
					} else if let errorMessage = store.errorMessage, store.apps.isEmpty {
						_statusView(
							title: .localized("Unable to Load Installed Apps"),
							description: errorMessage,
							systemImage: "iphone.slash",
							retry: {
								Task { await store.refresh() }
							}
						)
					} else if store.apps.isEmpty {
						_statusView(
							title: .localized("No Sideloaded Apps"),
							description: .localized("No sideloaded applications were found on this device."),
							systemImage: "square.stack.3d.up.slash"
						)
					}
				}
			}
			.animation(.spring(response: 0.35, dampingFraction: 0.85), value: installationManager.activeApp != nil)
			.task {
				guard loadsApps else { return }
				await store.load()
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Feather.installedAppsRefresh"))) { _ in
				Task {
					await store.refresh()
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: .heartbeat)) { _ in
				Task {
					await localDevVPN.refresh()
				}
			}
		}
	}

	private func _statusView(
		title: String,
		description: String,
		systemImage: String,
		retry: (() -> Void)? = nil
	) -> some View {
		VStack(spacing: 10) {
			Image(systemName: systemImage)
				.font(.largeTitle)
				.foregroundStyle(.secondary)
			Text(title)
				.font(.headline)
			Text(description)
				.font(.subheadline)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
			if let retry {
				Button(.localized("Retry"), action: retry)
					.buttonStyle(.borderedProminent)
			}
		}
		.padding()
	}
}

@MainActor
private final class LocalDevVPNConnectionMonitor: ObservableObject {
	@Published private(set) var isConnected = false
	@Published private(set) var isUpdating = false
	@Published private(set) var hasPairingFile: Bool

	private var refreshID = UUID()

	init() {
		hasPairingFile = FileManager.default.fileExists(
			atPath: HeartbeatManager.pairingFile()
		)
	}

	func refresh() async {
		let currentRefreshID = UUID()
		refreshID = currentRefreshID
		hasPairingFile = FileManager.default.fileExists(
			atPath: HeartbeatManager.pairingFile()
		)
		guard hasPairingFile else {
			isConnected = false
			return
		}

		let isDeviceReachable = await Task.detached(priority: .utility) {
			HeartbeatManager.shared.checkDeviceConnection(timeoutInSeconds: 1).isConnected
		}.value

		guard !Task.isCancelled, refreshID == currentRefreshID else { return }
		isConnected = isDeviceReachable
	}

	func setConnection(enabled: Bool) {
		guard !isUpdating, enabled != isConnected else { return }

		let action = enabled ? "enable" : "disable"
		guard let url = URL(string: "localdevvpn://\(action)?scheme=feather") else { return }

		refreshID = UUID()
		isUpdating = true
		isConnected = enabled
		UIApplication.shared.open(url, options: [:]) { [weak self] didOpen in
			Task { @MainActor [weak self] in
				guard let self else { return }
				guard didOpen else {
					self.isConnected = !enabled
					self.isUpdating = false
					return
				}

				try? await Task.sleep(nanoseconds: 1_500_000_000)
				guard !Task.isCancelled else { return }
				await self.refresh()
				self.isUpdating = false
			}
		}
	}
}

private struct DeviceConnectionStatusCard: View {
	@AppStorage("Feather.installationMethod") private var installationMethod = 0
	@ObservedObject var connection: LocalDevVPNConnectionMonitor

	var body: some View {
		VStack(spacing: 0) {
			HStack {
				DeviceStatusRowLabel(
					title: "Mode",
					systemImage: _installationMethodIcon
				)
				Spacer()
				Button {
					AppTabManager.shared.openInstallationSettings()
				} label: {
					HStack(spacing: 5) {
						Text(_installationMethodName)
						Image(systemName: "chevron.right")
							.font(.caption2.weight(.semibold))
							.foregroundStyle(.tertiary)
					}
					.font(.subheadline.weight(.medium))
					.foregroundStyle(.primary)
				}
				.buttonStyle(.plain)
				.accessibilityLabel("Open installation settings")
			}
			.padding(.horizontal, 14)
			.padding(.vertical, 12)

			Divider()
				.padding(.leading, 14)

			HStack {
				DeviceStatusRowLabel(title: "VPN", systemImage: "network")
				Spacer()

				Toggle("", isOn: Binding(
					get: { connection.isConnected },
					set: { connection.setConnection(enabled: $0) }
				))
				.labelsHidden()
				.tint(.green)
				.disabled(connection.isUpdating)
				.accessibilityLabel("VPN")
				.accessibilityValue(connection.isConnected ? "On" : "Off")
			}
			.padding(.horizontal, 14)
			.padding(.vertical, 10)
		}
		.background(Color(UIColor.secondarySystemGroupedBackground))
		.clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
		.overlay {
			RoundedRectangle(cornerRadius: 16, style: .continuous)
				.stroke(Color.primary.opacity(0.06), lineWidth: 1)
		}
		.task {
			while !Task.isCancelled {
				await connection.refresh()
				do {
					try await Task.sleep(nanoseconds: 5_000_000_000)
				} catch {
					break
				}
			}
		}
	}

	private var _installationMethodName: String {
		installationMethod == 1 ? .localized("idevice") : .localized("Server")
	}

	private var _installationMethodIcon: String {
		installationMethod == 1 ? "iphone" : "server.rack"
	}
}

private struct DeviceStatusRowLabel: View {
	let title: String
	let systemImage: String

	var body: some View {
		HStack(spacing: 9) {
			Image(systemName: systemImage)
				.font(.subheadline.weight(.medium))
				.frame(width: 18)
			Text(title)
		}
		.foregroundStyle(.secondary)
	}
}
private struct InstalledAppCellView: View {
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
	}
}

private struct InstalledAppIconView: View {
	let bundleIdentifier: String
	let cacheVersion: String
	let loadsIcon: Bool
	@State private var image: UIImage?

	var body: some View {
		Group {
			if let image {
				Image(uiImage: image).appIconStyle(size: 57)
			} else {
				Image("App_Unknown").appIconStyle(size: 57)
			}
		}
		.task(id: bundleIdentifier + "|" + cacheVersion) {
			guard loadsIcon else { return }
			image = try? await InstallationAppProxy.getAppIconCached(
				for: bundleIdentifier,
				cacheVersion: cacheVersion
			)
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
