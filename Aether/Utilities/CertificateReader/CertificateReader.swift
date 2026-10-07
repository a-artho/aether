//
//  CertificateReader.swift
//  Aether
//
//  Created by samara on 16.04.2025.
//

import UIKit
import OSLog

class CertificateReader: NSObject {
	let file: URL?
	var decoded: Certificate?
	
	init(_ file: URL?) {
		self.file = file
		super.init()
		self.decoded = self._readAndDecode()
	}
	
	private func _readAndDecode() -> Certificate? {
		guard let file = file else { return nil }
		
		do {
			let fileData = try Data(contentsOf: file)
			
			guard let xmlRange = fileData.range(of: Data("<?xml".utf8)) else {
				Logger.misc.error("XML start not found")
				return nil
			}
			
			let xmlData = fileData.subdata(in: xmlRange.lowerBound..<fileData.endIndex)
			
			let decoder = PropertyListDecoder()
			let data = try decoder.decode(Certificate.self, from: xmlData)
			return data
		} catch {
			Logger.misc.error("Error extracting certificate: \(error.localizedDescription)")
			return nil
		}
	}
}

// Kept separate from UI and signing side effects so identity planning can be tested.
enum AetherSigningIdentity {
	static func isAether(_ info: NSDictionary) -> Bool {
		guard info["CFBundleExecutable"] as? String == "Aether",
			let types = info["CFBundleURLTypes"] as? [[String: Any]],
			types.contains(where: { ($0["CFBundleURLSchemes"] as? [String])?.contains("aether") == true }),
			let declarations = info["UTExportedTypeDeclarations"] as? [[String: Any]] else { return false }
		return declarations.contains { $0["UTTypeIdentifier"] as? String == "com.anfear.aether.ipa" }
	}

	static func bundleIdentifier(applicationIdentifier: String?) throws -> String {
		guard let applicationIdentifier,
			let separator = applicationIdentifier.firstIndex(of: "."),
			separator != applicationIdentifier.startIndex else { throw Failure.invalidProfile }
		let prefix = applicationIdentifier[..<separator]
		let identifier = String(applicationIdentifier[applicationIdentifier.index(after: separator)...])
		guard !identifier.contains("*") else { throw Failure.wildcardProfile }
		let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
		guard prefix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
			!identifier.isEmpty,
			identifier.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({
				!$0.isEmpty && $0.allSatisfy { allowed.contains($0) }
			}) else { throw Failure.invalidProfile }
		return identifier
	}

	static func rewrite(_ identifier: String, old: String, new: String) -> String {
		guard !old.isEmpty, old != new else { return identifier }
		if identifier == old { return new }
		guard identifier.hasPrefix(old + ".") else { return identifier }
		return new + identifier.dropFirst(old.count)
	}

	static func rewriteAetherNamespace(_ identifier: String, old: String, new: String) -> String {
		// An externally renamed Aether may retain original extension/task identifiers.
		let roots = Set([old, "com.anfear.aether"]).sorted { $0.count > $1.count }
		guard let root = roots.first(where: { identifier == $0 || identifier.hasPrefix($0 + ".") }) else { return identifier }
		return rewrite(identifier, old: root, new: new)
	}

	static func updateTaskIdentifiers(in info: NSMutableDictionary, old: String, new: String) {
		guard let identifiers = info["BGTaskSchedulerPermittedIdentifiers"] as? [String] else { return }
		info["BGTaskSchedulerPermittedIdentifiers"] = identifiers.map {
			rewriteAetherNamespace($0, old: old, new: new)
		}
	}

	static func updateMainDeclarations(in info: NSMutableDictionary, old: String, new: String) {
		updateTaskIdentifiers(in: info, old: old, new: new)
		if var types = info["CFBundleURLTypes"] as? [[String: Any]] {
			for index in types.indices {
				if let name = types[index]["CFBundleURLName"] as? String {
					types[index]["CFBundleURLName"] = rewriteAetherNamespace(name, old: old, new: new)
				}
			}
			info["CFBundleURLTypes"] = types
		}
	}

	static func validateOptions(signingWithCertificate: Bool, customEntitlements: Bool,
		mergeEntitlements: Bool, removeURLScheme: Bool, removeProvisioning: Bool) throws {
		guard signingWithCertificate else { throw Failure.certificateRequired }
		guard !customEntitlements, !mergeEntitlements else { throw Failure.customEntitlements }
		guard !removeURLScheme, !removeProvisioning else { throw Failure.removalOptions }
	}

	enum Failure: LocalizedError {
		case invalidProfile, wildcardProfile, certificateRequired, customEntitlements, removalOptions, notAether, expiredProfile
		var errorDescription: String? {
			switch self {
			case .invalidProfile: return .localized("The selected profile does not contain a valid application identifier.")
			case .wildcardProfile: return .localized("This profile uses a wildcard and has no single bundle identifier to choose. Turn off Match Certificate Identity to keep your identifier.")
			case .certificateRequired: return .localized("Match Certificate Identity requires certificate signing and a selected certificate.")
			case .customEntitlements: return .localized("Turn off entitlement merging and remove custom entitlements before matching Aether to the certificate identity.")
			case .removalOptions: return .localized("Keep URL schemes and the provisioning profile enabled when matching Aether to the certificate identity.")
			case .notAether: return .localized("Match Certificate Identity is only available when signing Aether.")
			case .expiredProfile: return .localized("The selected provisioning profile has expired.")
			}
		}
	}
}
