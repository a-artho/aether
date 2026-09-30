import Foundation
@testable import IDeviceSwift
import XCTest

final class AppInstallationProvenanceTests: XCTestCase {
	func testAppStoreSignerIsAppStore() throws {
		let app = try appInfo(signer: "Apple iPhone OS Application Signing")
		XCTAssertEqual(classify(app), .appStore)
	}

	func testAppleDevelopmentSignerIsSideloaded() throws {
		XCTAssertEqual(classify(try appInfo(signer: "Apple Development: Example")), .sideloaded)
	}

	func testAppleDistributionSignerIsSideloaded() throws {
		XCTAssertEqual(classify(try appInfo(signer: "Apple Distribution: Example")), .sideloaded)
	}

	func testIPhoneDistributionSignerIsSideloaded() throws {
		XCTAssertEqual(classify(try appInfo(signer: "iPhone Distribution: Example")), .sideloaded)
	}

	func testArbitraryEnterpriseSignerIsSideloaded() throws {
		XCTAssertEqual(classify(try appInfo(signer: "Example Corporation")), .sideloaded)
	}

	func testMissingSignerWithAppStoreMetadataIsAppStore() throws {
		XCTAssertEqual(classify(try appInfo(hasSINF: true)), .appStore)
	}

	func testMissingSignerWithMatchingValidProfileIsSideloaded() throws {
		let app = try appInfo(
			bundleIdentifier: "com.example.aether",
			entitlements: [
				"com.apple.developer.team-identifier": "TEAM123456",
				"application-identifier": "TEAM123456.com.example.aether"
			]
		)
		let profile = try XCTUnwrap(profileInfo(applicationIdentifier: "TEAM123456.com.example.*"))
		XCTAssertEqual(classify(app, profiles: [profile]), .sideloaded)
	}

	func testMissingSignerWithoutEvidenceIsUnknown() throws {
		XCTAssertEqual(classify(try appInfo()), .unknown)
	}

	func testProfileWithoutDeclaredTeamIsNotTrusted() throws {
		let app = try appInfo()
		let profile = try XCTUnwrap(profileInfo(
			applicationIdentifier: "TEAM123456.com.example.*",
			teamIdentifiers: []
		))
		XCTAssertEqual(classify(app, profiles: [profile]), .unknown)
	}

	func testProfileWithMismatchedAppTeamEntitlementIsNotTrusted() throws {
		let app = try appInfo(
			entitlements: [
				"com.apple.developer.team-identifier": "OTHERTEAM1",
				"application-identifier": "OTHERTEAM1.com.example.aether"
			]
		)
		let profile = try XCTUnwrap(profileInfo(applicationIdentifier: "TEAM123456.com.example.*"))
		XCTAssertEqual(classify(app, profiles: [profile]), .unknown)
	}

	func testProfileWithMismatchedAppIdentifierEntitlementIsNotTrusted() throws {
		let app = try appInfo(
			entitlements: [
				"com.apple.developer.team-identifier": "TEAM123456",
				"application-identifier": "TEAM123456.com.example.other"
			]
		)
		let profile = try XCTUnwrap(profileInfo(applicationIdentifier: "TEAM123456.com.example.*"))
		XCTAssertEqual(classify(app, profiles: [profile]), .unknown)
	}

	func testEntitlementDeclaredProfileTeamCanMatch() throws {
		let app = try appInfo(
			entitlements: [
				"com.apple.developer.team-identifier": "TEAM123456",
				"application-identifier": "TEAM123456.com.example.aether"
			]
		)
		let profile = try XCTUnwrap(profileInfo(
			applicationIdentifier: "TEAM123456.com.example.*",
			teamIdentifiers: [],
			entitlementTeamIdentifier: "TEAM123456"
		))
		XCTAssertEqual(classify(app, profiles: [profile]), .sideloaded)
	}

	func testWildcardProfileWithoutAppIdentityRemainsUnknown() throws {
		let app = try appInfo()
		let profile = try XCTUnwrap(profileInfo(applicationIdentifier: "TEAM123456.*"))
		XCTAssertEqual(classify(app, profiles: [profile]), .unknown)
	}

	private func classify(
		_ app: AppInfo,
		profiles: [ProvisioningProfileInfo] = []
	) -> AppInstallationProvenance {
		AppInstallationProvenanceClassifier.classify(
			app,
			profiles: profiles,
			now: Date(timeIntervalSince1970: 1_000)
		)
	}

	private func appInfo(
		bundleIdentifier: String = "com.example.aether",
		signer: String? = nil,
		hasSINF: Bool = false,
		entitlements: [String: String]? = nil
	) throws -> AppInfo {
		var plist: [String: Any] = ["CFBundleIdentifier": bundleIdentifier]
		plist["SignerIdentity"] = signer
		if hasSINF { plist["ApplicationSINF"] = Data([0x01]) }
		plist["Entitlements"] = entitlements
		let data = try PropertyListSerialization.data(
			fromPropertyList: plist,
			format: .binary,
			options: 0
		)
		return try PropertyListDecoder().decode(AppInfo.self, from: data)
	}

	private func profileInfo(
		applicationIdentifier: String,
		teamIdentifiers: [String] = ["TEAM123456"],
		entitlementTeamIdentifier: String? = nil
	) throws -> ProvisioningProfileInfo? {
		var entitlements: [String: Any] = ["application-identifier": applicationIdentifier]
		entitlements["com.apple.developer.team-identifier"] = entitlementTeamIdentifier
		let plist: [String: Any] = [
			"ExpirationDate": Date(timeIntervalSince1970: 10_000),
			"TeamIdentifier": teamIdentifiers,
			"ProvisionedDevices": ["device"],
			"Entitlements": entitlements
		]
		let data = try PropertyListSerialization.data(
			fromPropertyList: plist,
			format: .xml,
			options: 0
		)
		return ProvisioningProfileInfo(data: data)
	}
}
