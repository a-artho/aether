//
//  InstalledAppsStore.swift
//  Feather
//

import Foundation
import IDeviceSwift

struct InstalledApp: Identifiable, Equatable {
	let bundleIdentifier: String
	let name: String
	let version: String?
	let build: String?

	var id: String { bundleIdentifier }
	var iconCacheVersion: String { "\(version ?? "")|\(build ?? "")" }
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
	}

	func load() async {
		await refresh()
	}

	func refresh() async {
		guard !isLoading else { return }
		isLoading = true
		errorMessage = nil
		defer { isLoading = false }

		let proxy = InstallationAppProxy()

		do {
			let installedApps = try await proxy.fetchApps(applicationType: "User")
			let hasUnresolvedApps = installedApps.contains {
				AppInstallationProvenanceClassifier.classify($0) == .unknown
			}
			let profiles: [ProvisioningProfileInfo]
			if hasUnresolvedApps {
				profiles = (try? await proxy.provisioningProfiles()) ?? []
			} else {
				profiles = []
			}
			updateApplications(with: installedApps, profiles: profiles)
		} catch is CancellationError {
			return
		} catch {
			errorMessage = error.localizedDescription
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
					build: app.CFBundleVersion
				)
			}
			.sorted {
				$0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
			}
	}
}
