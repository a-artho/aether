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
				if let activeApp = installationManager.activeApp, let vm = installationManager.viewModel {
					ActiveInstallationHeroCard(app: activeApp, viewModel: vm)
						.padding(.horizontal)
						.padding(.top, 8)
						.padding(.bottom, 6)
						.transition(.move(edge: .top).combined(with: .opacity))
				}

				NBListAdaptable {
					if !store.apps.isEmpty {
						NBSection(
							.localized("Sideloaded"),
							secondary: store.apps.count.description
						) {
							ForEach(store.apps) { app in
								InstalledAppCellView(app: app, loadsIcon: loadsIcons)
							}
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
