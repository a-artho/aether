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
		let app = try appInfo(bundleIdentifier: "com.example.feather")
		let profile = try XCTUnwrap(profileInfo(applicationIdentifier: "TEAM123456.com.example.*"))
		XCTAssertEqual(classify(app, profiles: [profile]), .sideloaded)
	}

	func testMissingSignerWithoutEvidenceIsUnknown() throws {
		XCTAssertEqual(classify(try appInfo()), .unknown)
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
		bundleIdentifier: String = "com.example.feather",
		signer: String? = nil,
		hasSINF: Bool = false
	) throws -> AppInfo {
		var plist: [String: Any] = ["CFBundleIdentifier": bundleIdentifier]
		plist["SignerIdentity"] = signer
		if hasSINF { plist["ApplicationSINF"] = Data([0x01]) }
		let data = try PropertyListSerialization.data(
			fromPropertyList: plist,
			format: .binary,
			options: 0
		)
		return try PropertyListDecoder().decode(AppInfo.self, from: data)
	}

	private func profileInfo(applicationIdentifier: String) throws -> ProvisioningProfileInfo? {
		let plist: [String: Any] = [
			"ExpirationDate": Date(timeIntervalSince1970: 10_000),
			"TeamIdentifier": ["TEAM123456"],
			"ProvisionedDevices": ["device"],
			"Entitlements": ["application-identifier": applicationIdentifier]
		]
		let data = try PropertyListSerialization.data(
			fromPropertyList: plist,
			format: .xml,
			options: 0
		)
		return ProvisioningProfileInfo(data: data)
	}
}
