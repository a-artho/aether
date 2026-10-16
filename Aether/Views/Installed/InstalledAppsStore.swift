//
//  InstalledAppsStore.swift
//  Aether
//

import Foundation
import SwiftUI
import IDeviceSwift

struct InstalledApp: Identifiable, Equatable, Hashable {
	let bundleIdentifier: String
	let name: String
	let version: String?
	let build: String?
	let appInfo: AppInfo?

	init(
		bundleIdentifier: String,
		name: String,
		version: String? = nil,
		build: String? = nil,
		appInfo: AppInfo? = nil
	) {
		self.bundleIdentifier = bundleIdentifier
		self.name = name
		self.version = version
		self.build = build
		self.appInfo = appInfo
	}

	var id: String { bundleIdentifier }
	var iconCacheVersion: String { "\(version ?? "")|\(build ?? "")|\(InstallationAppProxy.iconCacheRevision(for: bundleIdentifier))" }

	static func == (lhs: InstalledApp, rhs: InstalledApp) -> Bool {
		lhs.bundleIdentifier == rhs.bundleIdentifier
			&& lhs.version == rhs.version
			&& lhs.build == rhs.build
	}

	func hash(into hasher: inout Hasher) {
		hasher.combine(bundleIdentifier)
		hasher.combine(version)
		hasher.combine(build)
	}

	var displayName: String {
		appInfo?.CFBundleDisplayName ?? appInfo?.CFBundleName ?? name
	}

	var executableName: String? {
		appInfo?.CFBundleExecutable
	}

	var minimumOSVersion: String? {
		appInfo?.MinimumOSVersion
	}

	var sdkName: String? {
		appInfo?.DTSDKName
	}

	var xcodeBuild: String? {
		appInfo?.DTXcodeBuild
	}

	var bundlePath: String? {
		appInfo?.Path
	}

	var containerPath: String? {
		appInfo?.Container
	}

	var signerIdentity: String? {
		appInfo?.SignerIdentity
	}

	var deviceFamilies: [String] {
		guard let families = appInfo?.UIDeviceFamily else { return ["iPhone"] }
		return families.map { family in
			switch family {
			case 1: return "iPhone"
			case 2: return "iPad"
			case 3: return "Apple TV"
			case 4: return "Apple Watch"
			case 7: return "Apple Vision"
			default: return "Device \(family)"
			}
		}
	}

	var registeredUrlSchemes: [String] {
		guard let urlTypes = appInfo?.CFBundleURLTypes else { return [] }
		var schemes: [String] = []
		for dict in urlTypes {
			if let array = dict["CFBundleURLSchemes"]?.value as? [String] {
				schemes.append(contentsOf: array)
			}
		}
		return schemes
	}

	var entitlementsList: [(key: String, value: String)] {
		guard let entitlements = appInfo?.Entitlements else { return [] }
		return entitlements.map { key, val in
			let desc: String
			if let s = val.value as? String {
				desc = s
			} else if let b = val.value as? Bool {
				desc = b ? "true" : "false"
			} else if let arr = val.value as? [Any] {
				desc = arr.map { "\($0)" }.joined(separator: ", ")
			} else if let d = val.value as? [String: Any] {
				desc = "\(d.count) items"
			} else {
				desc = "\(val.value)"
			}
			return (key: key, value: desc)
		}.sorted { $0.key < $1.key }
	}
}

@MainActor
final class InstalledAppsStore: NSObject, ObservableObject {
	static let shared = InstalledAppsStore()
	@Published private(set) var hasLoadedApps = false
	private var lastLoadedAt: Date?
	private var verifiedApps: [AppInfo]?
	private var initialBrowse: Task<[AppInfo]?, Never>?
	private var needsTrailingRefresh = false
	private var refreshGeneration = UUID()
	private var iconPrefetchTask: Task<Void, Never>?
	@Published private(set) var apps: [InstalledApp]
	@Published private(set) var isLoading: Bool
	@Published private(set) var errorMessage: String?

	init(
		apps: [InstalledApp] = [],
		isLoading: Bool = false,
		errorMessage: String? = nil
	) {
		self.apps = apps
		self.isLoading = isLoading
		self.errorMessage = errorMessage
		super.init()
		#if DEBUG
		NotificationCenter.default.addObserver(forName: Notification.Name("Aether.mockApps"), object: nil, queue: .main) { [weak self] _ in
			Task { @MainActor [weak self] in
				guard let self else { return }
				let sampleApps: [(name: String, id: String, ver: String, build: String)] = [
					("Delta", "com.rileytestut.Delta", "1.6.2", "240"),
					("Apollo", "com.christianselig.apollo", "1.15.11", "189"),
					("RetroArch", "org.libretro.RetroArch", "1.19.1", "1"),
					("Enmity", "com.discord.enmity", "214.0", "452"),
					("TrollStore", "com.opa334.TrollStore", "2.0.15", "1")
				]
				self.apps = sampleApps.map { item in
					let mockAppInfo = AppInfo(
						CFBundleName: item.name,
						DTXcodeBuild: "15C500b",
						Entitlements: [
							"application-identifier": IDeviceSwift.AnyCodable("TEAMID.\(item.id)"),
							"com.apple.developer.team-identifier": IDeviceSwift.AnyCodable("TEAMID"),
							"get-task-allow": IDeviceSwift.AnyCodable(false),
							"keychain-access-groups": IDeviceSwift.AnyCodable(["TEAMID.\(item.id)"])
						],
						CFBundleURLTypes: [
							["CFBundleURLSchemes": IDeviceSwift.AnyCodable([item.name.lowercased()])]
						],
						CFBundleDisplayName: item.name,
						CFBundleExecutable: item.name,
						DTSDKName: "iphoneos17.2",
						Container: "/private/var/mobile/Containers/Data/Application/\(UUID().uuidString)",
						MinimumOSVersion: "15.0",
						CFBundleIdentifier: item.id,
						Path: "/private/var/containers/Bundle/Application/\(UUID().uuidString)/\(item.name).app",
						CFBundleVersion: item.build,
						CFBundleShortVersionString: item.ver,
						UIDeviceFamily: [1, 2]
					)
					return InstalledApp(
						bundleIdentifier: item.id,
						name: item.name,
						version: item.ver,
						build: item.build,
						appInfo: mockAppInfo
					)
				}
				self.errorMessage = nil
			}
		}
		NotificationCenter.default.addObserver(forName: Notification.Name("Aether.clearApps"), object: nil, queue: .main) { [weak self] _ in
			Task { @MainActor [weak self] in
				guard let self else { return }
				self.clear()
			}
		}
		#endif
	}

	func load() async {
		guard !hasLoadedApps else { return }
		await refresh()
	}

	func stageVerifiedApps(_ apps: [AppInfo]) { verifiedApps = apps }

	func stageInitialBrowse(_ task: Task<[AppInfo]?, Never>) {
		initialBrowse?.cancel()
		initialBrowse = task
	}

	func refreshOnForeground() async {
		guard DeviceConnectionManager.shared.isConnected else { return }
		guard !hasLoadedApps || Date().timeIntervalSince(lastLoadedAt ?? .distantPast) >= 60 else { return }
		await refresh()
	}

	func clear() {
		initialBrowse?.cancel()
		initialBrowse = nil
		verifiedApps = nil
		lastLoadedAt = nil
		hasLoadedApps = false
		iconPrefetchTask?.cancel()
		iconPrefetchTask = nil
		needsTrailingRefresh = false
		refreshGeneration = UUID()
		self.apps = []
		self.errorMessage = nil
		self.isLoading = false
	}

	func delete(app: InstalledApp) async throws {
		let installations = AppInstallationManager.shared
		guard installations.beginUninstall(bundleIdentifier: app.bundleIdentifier) else {
			throw NSError(domain: "Aether.Uninstall", code: 1, userInfo: [
				NSLocalizedDescriptionKey: String.localized("This app is being installed or uninstalled. Wait for that operation to finish.")
			])
		}
		defer { installations.endUninstall(bundleIdentifier: app.bundleIdentifier) }
		try await AppLifecycleService.uninstallApp(bundleIdentifier: app.bundleIdentifier)
		// A refresh may have fetched this app before the uninstall completed.
		refreshGeneration = UUID()
		isLoading = false
		needsTrailingRefresh = false
		iconPrefetchTask?.cancel()
		iconPrefetchTask = nil
		withAnimation(.easeOut(duration: 0.25)) {
			self.apps.removeAll { $0.id == app.id }
		}
	}

	func refresh(force: Bool = false) async {
		guard DeviceConnectionManager.shared.isConnected else {
			hasLoadedApps = false
			refreshGeneration = UUID()
			needsTrailingRefresh = false
			isLoading = false
			#if DEBUG
			if !self.apps.isEmpty {
				return
			}
			#endif
			self.apps = []
			self.errorMessage = nil
			return
		}
		guard !isLoading else {
			needsTrailingRefresh = needsTrailingRefresh || force
			return
		}
		let generation = UUID()
		refreshGeneration = generation
		isLoading = true
		errorMessage = nil
		defer {
			if refreshGeneration == generation {
				isLoading = false
				let shouldRefresh = needsTrailingRefresh && !Task.isCancelled
				needsTrailingRefresh = false
				if shouldRefresh {
					Task { [weak self] in
						guard let self, self.refreshGeneration == generation else { return }
						await self.refresh()
					}
				}
			}
		}

		let proxy = InstallationAppProxy()

		do {
			let lookupStarted = ProcessInfo.processInfo.systemUptime
			let pending = initialBrowse
			initialBrowse = nil
			let pendingApps = force ? nil : await pending?.value
			try Task.checkCancellation()
			guard refreshGeneration == generation, DeviceConnectionManager.shared.isConnected else { return }
			let staged = verifiedApps ?? pendingApps
			verifiedApps = nil
			let installedApps: [AppInfo]
			if let staged, !force { installedApps = staged }
			else { installedApps = try await proxy.fetchApps(applicationType: "User", lightweight: true) }
			guard refreshGeneration == generation, DeviceConnectionManager.shared.isConnected, !Task.isCancelled else { return }
			DebugLogManager.shared.log("App lookup seconds=\(ProcessInfo.processInfo.systemUptime - lookupStarted) reusedVerification=\(staged != nil && !force) count=\(installedApps.count).", category: "Device", level: .debug)
			// Start the first screen's icons while any fallback profiles are loading.
			// The list never waits for this work; row requests share the same cache/task.
			// Publish confirmed rows immediately and warm only the first screen.
			if apps.isEmpty { updateApplications(with: installedApps, profiles: []) }
			prefetchFirstScreenIcons()
			let profiles: [ProvisioningProfileInfo]
			if installedApps.contains(where: AppInstallationProvenanceClassifier.needsProvisioningProfile) {
				do {
					let profilesStarted = ProcessInfo.processInfo.systemUptime
					profiles = try await proxy.provisioningProfiles()
					DebugLogManager.shared.log("Profile fallback seconds=\(ProcessInfo.processInfo.systemUptime - profilesStarted).", category: "Device", level: .debug)
					DebugLogManager.shared.log(
						"Loaded \(profiles.count) provisioning profile\(profiles.count == 1 ? "" : "s") from the device.",
						category: "Device"
					)
				} catch {
					DebugLogManager.shared.log(
						"Could not load provisioning profiles: \(error.localizedDescription)",
						category: "Device",
						level: .error
					)
					throw error
				}
			} else {
				profiles = []
				DebugLogManager.shared.log(
					"Skipped provisioning profiles: no installed apps need profile-based classification.",
					category: "Device"
				)
			}
			guard refreshGeneration == generation, DeviceConnectionManager.shared.isConnected, !Task.isCancelled else { return }
			updateApplications(with: installedApps, profiles: profiles)
			prefetchFirstScreenIcons()
			hasLoadedApps = true
			lastLoadedAt = Date()
			DebugLogManager.shared.log(
				"Loaded \(apps.count) sideloaded app\(apps.count == 1 ? "" : "s") from the device.",
				category: "Device"
			)
		} catch is CancellationError {
			return
		} catch {
			guard refreshGeneration == generation, DeviceConnectionManager.shared.isConnected, !Task.isCancelled else { return }
			errorMessage = error.localizedDescription
			DebugLogManager.shared.log(
				"Could not load sideloaded apps: \(error.localizedDescription)",
				category: "Device",
				level: .error
			)
		}
	}

	private func prefetchFirstScreenIcons() {
		iconPrefetchTask?.cancel()
		// Use the displayed order, including apps confirmed by profile fallback.
		// Cache hits and in-flight requests are shared with visible rows.
		let firstScreen = Array(apps.prefix(8))
		iconPrefetchTask = Task {
			for app in firstScreen {
				guard !Task.isCancelled else { return }
				_ = try? await InstallationAppProxy.getAppIconCached(
					for: app.bundleIdentifier, cacheVersion: app.iconCacheVersion)
			}
		}
	}

	private func updateApplications(
		with apps: [AppInfo],
		profiles: [ProvisioningProfileInfo]
	) {
		self.apps = apps
			.filter { app in
				let provenance = AppInstallationProvenanceClassifier.classify(
					app,
					profiles: profiles
				)
				#if DEBUG
				print(
					"Installed app classification:",
					app.CFBundleIdentifier ?? "<missing bundle id>",
					"signer:", app.SignerIdentity ?? "<missing>",
					"DSID:", app.ApplicationDSID != nil,
					"SINF:", app.ApplicationSINF != nil,
					"iTunes:", app.iTunesMetadata != nil,
					"result:", provenance
				)
				#endif
				return provenance == .sideloaded
			}
			.compactMap { app in
				guard let bundleIdentifier = app.CFBundleIdentifier else { return nil }
				let name = app.CFBundleDisplayName ?? app.CFBundleName ?? bundleIdentifier

				return InstalledApp(
					bundleIdentifier: bundleIdentifier,
					name: name,
					version: app.CFBundleShortVersionString,
					build: app.CFBundleVersion,
					appInfo: app
				)
			}
			.sorted {
				$0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
			}
	}
}
