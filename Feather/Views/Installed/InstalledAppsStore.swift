//
//  InstalledAppsStore.swift
//  Feather
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
	let profileInfo: ProvisioningProfileInfo?

	init(
		bundleIdentifier: String,
		name: String,
		version: String? = nil,
		build: String? = nil,
		appInfo: AppInfo? = nil,
		profileInfo: ProvisioningProfileInfo? = nil
	) {
		self.bundleIdentifier = bundleIdentifier
		self.name = name
		self.version = version
		self.build = build
		self.appInfo = appInfo
		self.profileInfo = profileInfo
	}

	var id: String { bundleIdentifier }
	var iconCacheVersion: String { "\(version ?? "")|\(build ?? "")" }

	static func == (lhs: InstalledApp, rhs: InstalledApp) -> Bool {
		lhs.bundleIdentifier == rhs.bundleIdentifier
			&& lhs.version == rhs.version
			&& lhs.build == rhs.build
			&& lhs.profileInfo == rhs.profileInfo
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
		NotificationCenter.default.addObserver(forName: Notification.Name("Feather.mockApps"), object: nil, queue: .main) { [weak self] _ in
			Task { @MainActor [weak self] in
				guard let self else { return }
				let sampleApps: [(name: String, id: String, ver: String, build: String, days: Int, type: String)] = [
					("Delta", "com.rileytestut.Delta", "1.6.2", "240", 5, "Free Apple ID (7 Days)"),
					("Apollo", "com.christianselig.apollo", "1.15.11", "189", 180, "Apple Developer (1 Year)"),
					("RetroArch", "org.libretro.RetroArch", "1.19.1", "1", 340, "Enterprise / In-House"),
					("Enmity", "com.discord.enmity", "214.0", "452", 0, "Free Apple ID (7 Days)"),
					("TrollStore", "com.opa334.TrollStore", "2.0.15", "1", 28, "Apple Developer (1 Year)")
				]
				self.apps = sampleApps.map { item in
					let expDate = Date().addingTimeInterval(Double(item.days * 86400) + 3600 * 14)
					let profile = ProvisioningProfileInfo(
						applicationIdentifier: "TEAMID.\(item.id)",
						expirationDate: expDate,
						teamIdentifiers: ["TEAMID"],
						entitlementTeamIdentifier: "TEAMID",
						provisionedDevices: ["00008101-0000000000000000"],
						provisionsAllDevices: item.type.contains("Enterprise"),
						name: "iOS Team Provisioning Profile: \(item.id)",
						teamName: "\(item.name) Developer Team",
						creationDate: expDate.addingTimeInterval(-86400 * 7),
						uuid: UUID().uuidString
					)
					return InstalledApp(
						bundleIdentifier: item.id,
						name: item.name,
						version: item.ver,
						build: item.build,
						appInfo: nil,
						profileInfo: profile
					)
				}
				self.errorMessage = nil
			}
		}
		NotificationCenter.default.addObserver(forName: Notification.Name("Feather.clearApps"), object: nil, queue: .main) { [weak self] _ in
			Task { @MainActor [weak self] in
				guard let self else { return }
				self.clear()
			}
		}
		#endif
	}

	func load() async {
		await refresh()
	}

	func clear() {
		self.apps = []
		self.errorMessage = nil
		self.isLoading = false
	}

	func delete(app: InstalledApp) async throws {
		try await AppLifecycleService.uninstallApp(bundleIdentifier: app.bundleIdentifier)
		withAnimation(.easeOut(duration: 0.25)) {
			self.apps.removeAll { $0.id == app.id }
		}
	}

	func refresh() async {
		guard DeviceConnectionManager.shared.isConnected else {
			#if DEBUG
			if !self.apps.isEmpty {
				return
			}
			#endif
			self.apps = []
			self.errorMessage = nil
			return
		}
		guard !isLoading else { return }
		isLoading = true
		errorMessage = nil
		defer { isLoading = false }

		let proxy = InstallationAppProxy()

		do {
			let installedApps = try await proxy.fetchApps(applicationType: "User")
			let profiles = (try? await proxy.provisioningProfiles()) ?? []
			updateApplications(with: installedApps, profiles: profiles)
			DebugLogManager.shared.log(
				"Loaded \(apps.count) sideloaded app\(apps.count == 1 ? "" : "s") from the device.",
				category: "Device"
			)
		} catch is CancellationError {
			return
		} catch {
			errorMessage = error.localizedDescription
			DebugLogManager.shared.log(
				"Could not load sideloaded apps: \(error.localizedDescription)",
				category: "Device",
				level: .error
			)
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

				let matchedProfile = profiles.first { profile in
					profile.matches(
						bundleIdentifier: bundleIdentifier,
						appTeamIdentifier: app.Entitlements?["com.apple.developer.team-identifier"]?.value as? String,
						appApplicationIdentifier: app.Entitlements?["application-identifier"]?.value as? String
					)
				}

				return InstalledApp(
					bundleIdentifier: bundleIdentifier,
					name: name,
					version: app.CFBundleShortVersionString,
					build: app.CFBundleVersion,
					appInfo: app,
					profileInfo: matchedProfile
				)
			}
			.sorted {
				$0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
			}
	}
}
