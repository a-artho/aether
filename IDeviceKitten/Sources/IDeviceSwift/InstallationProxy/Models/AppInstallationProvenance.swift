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
		return profiles.contains(where: { $0.matches(bundleIdentifier: bundleIdentifier, now: now) })
			? .sideloaded
			: .unknown
	}
}
