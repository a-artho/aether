//
//  AppInstallationProvenance.swift
//  IDeviceKit
//

import Foundation

public enum AppInstallationProvenance: Equatable, Sendable {
	case appStore
	case sideloaded
	case unknown
}

public enum AppInstallationProvenanceClassifier {
	private static let appStoreSigner = "Apple iPhone OS Application Signing"

	/// Profiles can only resolve apps with signing entitlements and no known origin.
	public static func needsProvisioningProfile(_ app: AppInfo) -> Bool {
		guard app.IsAppClip != true, app.IsDemotedApp != true,
			app.CFBundleIdentifier != nil, classify(app) == .unknown else {
			return false
		}
		return app.Entitlements?["com.apple.developer.team-identifier"]?.value as? String != nil
			|| app.Entitlements?["application-identifier"]?.value as? String != nil
	}

	public static func classify(
		_ app: AppInfo,
		profiles: [ProvisioningProfileInfo] = [],
		now: Date = Date()
	) -> AppInstallationProvenance {
		guard app.IsAppClip != true, app.IsDemotedApp != true else {
			return .unknown
		}

		let signer = app.SignerIdentity?
			.trimmingCharacters(in: .whitespacesAndNewlines)

		if signer == appStoreSigner {
			return .appStore
		}
		if let signer, !signer.isEmpty {
			return .sideloaded
		}

		if app.ApplicationSINF != nil || app.iTunesMetadata != nil || app.ApplicationDSID != nil {
			return .appStore
		}

		guard let bundleIdentifier = app.CFBundleIdentifier else {
			return .unknown
		}
		let teamIdentifier = app.Entitlements?["com.apple.developer.team-identifier"]?.value as? String
		let applicationIdentifier = app.Entitlements?["application-identifier"]?.value as? String
		guard teamIdentifier != nil || applicationIdentifier != nil else {
			return .unknown
		}
		return profiles.contains(where: {
			$0.matches(
				bundleIdentifier: bundleIdentifier,
				appTeamIdentifier: teamIdentifier,
				appApplicationIdentifier: applicationIdentifier,
				now: now
			)
		})
			? .sideloaded
			: .unknown
	}
}
