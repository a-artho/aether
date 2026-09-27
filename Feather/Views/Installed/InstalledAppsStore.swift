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
}

@MainActor
final class InstalledAppsStore: NSObject, ObservableObject {
	@Published private(set) var apps: [InstalledApp]
	@Published private(set) var isLoading: Bool
	@Published private(set) var errorMessage: String?

	private var proxy: InstallationAppProxy?
	private var hasLoaded = false

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
		guard !hasLoaded, !isLoading else { return }
		hasLoaded = true
		isLoading = true
		errorMessage = nil

		let proxy = InstallationAppProxy()
		proxy.delegate = self
		self.proxy = proxy

		do {
			try await proxy.listApps(applicationType: "User")
		} catch is CancellationError {
			hasLoaded = false
		} catch {
			errorMessage = error.localizedDescription
		}

		self.proxy = nil
		isLoading = false
	}
}

extension InstalledAppsStore: InstallationProxyAppsDelegate {
	func updateApplications(with apps: [AppInfo]) {
		self.apps = apps
			.filter(Self._isSideloaded)
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

	private static func _isSideloaded(_ app: AppInfo) -> Bool {
		guard app.IsAppClip != true, app.IsDemotedApp != true else { return false }

		let signer = app.SignerIdentity?.lowercased() ?? ""
		let developerSignerMarkers = [
			"apple development",
			"apple distribution",
			"iphone developer",
			"iphone distribution"
		]
		if developerSignerMarkers.contains(where: signer.contains) {
			return true
		}

		let hasAppStoreMetadata = app.ApplicationSINF != nil
			|| app.iTunesMetadata != nil
			|| app.ApplicationDSID != nil
		return !hasAppStoreMetadata
	}
}
