//
//  InstalledAppsView.swift
//  Feather
//

import IDeviceSwift
import NimbleViews
import SwiftUI

@MainActor
struct InstalledAppsView: View {
	@AppStorage("Feather.installationMethod") private var installationMethod = 0
	@StateObject private var store: InstalledAppsStore
	@ObservedObject private var installationManager = AppInstallationManager.shared
	@ObservedObject private var connection = DeviceConnectionManager.shared
	@ObservedObject private var tabManager = AppTabManager.shared
	@State private var topCardMaxY: CGFloat = 160
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
			ZStack(alignment: .top) {
				ScrollViewReader { scrollProxy in
					List {
						Section {
							_modeVpnCard
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
									InstalledAppCellView(app: app, loadsIcon: loadsIcons)
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
					.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Feather.testScrollDevice"))) { _ in
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
						let tabbarClearance: CGFloat = 95
						let bottomEdge = max(cardBottom + 50, rootGeo.size.height - tabbarClearance)
						let availableHeight = bottomEdge - cardBottom
						let centerY = cardBottom + (availableHeight / 2)

						_placeholderContent
							.frame(width: rootGeo.size.width)
							.position(x: rootGeo.size.width / 2, y: centerY)
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
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Feather.installedAppsRefresh"))) { _ in
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
				ToolbarItem(placement: .topBarTrailing) {
					Button {
						tabManager.isSettingsPresented = true
					} label: {
						Image(systemName: "gear")
					}
					.accessibilityLabel(.localized("Settings"))
				}
			}
			.sheet(isPresented: $tabManager.isSettingsPresented) {
				SettingsView()
			}
		}
	}

	private var _modeVpnCard: some View {
		VStack(spacing: 0) {
			Button {
				tabManager.openInstallationSettings()
			} label: {
				HStack(spacing: 12) {
					SettingsIconBadge(
						systemImage: _installationMethodIcon,
						backgroundColor: _installationMethodColor,
						iconSize: installationMethod == 1 ? 16 : 14
					)

					Text(.localized("Mode"))
						.foregroundColor(.primary)

					Spacer()

					Text(_installationMethodName)
						.foregroundColor(.secondary)

					Image(systemName: "chevron.right")
						.font(.footnote.weight(.semibold))
						.foregroundColor(Color(UIColor.tertiaryLabel))
				}
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.padding(.horizontal, 16)
			.padding(.vertical, 12)

			Divider()
				.padding(.leading, 56)

			HStack(spacing: 12) {
				SettingsIconBadge(
					systemImage: "network",
					backgroundColor: .green,
					iconSize: 15
				)

				Text(.localized("VPN"))
					.foregroundColor(.primary)

				if connection.isUpdating {
					ProgressView()
						.controlSize(.small)
						.padding(.leading, 4)
				}

				Spacer()

				Toggle("", isOn: Binding(
					get: { connection.isConnected },
					set: { connection.setConnection(enabled: $0) }
				))
				.labelsHidden()
				.tint(.green)
				.disabled(connection.isUpdating)
			}
			.padding(.horizontal, 16)
			.padding(.vertical, 10)
		}
		.background(Color(UIColor.secondarySystemGroupedBackground))
		.clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
		.overlay {
			RoundedRectangle(cornerRadius: 16, style: .continuous)
				.stroke(Color.primary.opacity(0.06), lineWidth: 1)
		}
	}

	private var _installationMethodName: String {
		installationMethod == 1 ? .localized("idevice") : .localized("Server")
	}

	private var _installationMethodIcon: String {
		installationMethod == 1 ? "iphone" : "server.rack"
	}

	private var _installationMethodColor: Color {
		installationMethod == 1 ? .purple : .blue
	}

	@ViewBuilder
	private var _placeholderContent: some View {
		if store.isLoading && store.apps.isEmpty {
			ProgressView()
				.padding(.vertical, 20)
		} else if !connection.hasPairingFile && store.apps.isEmpty {
			_statusView(
				title: .localized("Pairing File Missing"),
				description: .localized("Import a pairing file to view sideloaded apps."),
				systemImage: "key.slash"
			)
		} else if !connection.isConnected && store.apps.isEmpty {
			_statusView(
				title: .localized("LocalDevVPN Is Off"),
				description: .localized("Turn on VPN to view sideloaded apps."),
				systemImage: "network.slash",
				actionTitle: .localized("Turn On VPN"),
				action: {
					connection.setConnection(enabled: true)
				}
			)
		} else if let errorMessage = store.errorMessage, store.apps.isEmpty {
			_statusView(
				title: .localized("Unable to Load Installed Apps"),
				description: errorMessage,
				systemImage: "iphone.slash",
				actionTitle: .localized("Retry"),
				action: {
					Task { await store.refresh() }
				}
			)
		} else {
			_statusView(
				title: .localized("No Sideloaded Apps"),
				description: .localized("Installed sideloaded apps will appear here."),
				systemImage: "square.stack.3d.up.slash"
			)
		}
	}

	private func _statusView(
		title: String,
		description: String,
		systemImage: String,
		actionTitle: String? = nil,
		action: (() -> Void)? = nil
	) -> some View {
		VStack(spacing: 12) {
			Image(systemName: systemImage)
				.font(.system(size: 40))
				.foregroundStyle(.secondary)
			Text(title)
				.font(.headline)
				.foregroundStyle(.primary)
			Text(description)
				.font(.subheadline)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
				.padding(.horizontal, 28)
			if let actionTitle, let action {
				Button(actionTitle, action: action)
					.buttonStyle(.borderedProminent)
					.padding(.top, 4)
			}
		}
		.frame(maxWidth: .infinity)
		.padding(.vertical, 16)
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
