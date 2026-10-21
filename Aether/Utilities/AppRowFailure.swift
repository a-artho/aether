import Foundation
import IDeviceSwift

/// Presentation only. Keep the original Error/message for diagnostics and details.
enum AppRowFailure {
	enum Stage {
		case signing, installation, download, processing, export
		var label: String {
			switch self {
			case .signing: return .localized("Signing")
			case .installation: return .localized("Installation")
			case .download: return .localized("Download")
			case .processing: return .localized("Import")
			case .export: return .localized("Export")
			}
		}
	}

	static func text(for error: Error, stage: Stage) -> String {
		if error is InstallationBackgroundError { return .localized("iOS interrupted background installation") }
		if let failure = error as? SigningFileHandlerError { return failure.localizedDescription }
		if let failure = error as? AetherSigningIdentity.Failure {
			switch failure {
			case .invalidProfile: return .localized("Invalid provisioning profile")
			case .wildcardProfile: return .localized("Profile needs an explicit ID")
			case .certificateRequired: return .localized("Select a signing certificate")
			case .customEntitlements: return .localized("Custom entitlements conflict")
			case .removalOptions: return .localized("Keep URL schemes and profile")
			case .notAether: return .localized("Identity matching needs Aether")
			case .expiredProfile: return .localized("Provisioning profile expired")
			}
		}
		if let failure = error as? BundlePackageWriter.Failure {
			switch failure {
			case .changedSource: return .localized("App changed during packaging")
			case .archive: return .localized("App packaging failed")
			}
		}
		let ns = error as NSError
		if ns.domain == NSCocoaErrorDomain {
			switch ns.code {
			case 640: return .localized("Not enough storage")
			case 4, 260: return .localized("App file not found")
			case 257, 513: return .localized("File access denied")
			default: break
			}
		}
		if ns.domain == NSPOSIXErrorDomain {
			switch ns.code {
			case 28: return .localized("Not enough storage")
			case 1, 13: return .localized("File access denied")
			case 2: return .localized("App file not found")
			default: break
			}
		}
		if ns.domain == NSURLErrorDomain {
			switch ns.code {
			case -1001: return .localized("Connection timed out")
			case -1009: return .localized("No internet connection")
			case -1005: return .localized("Connection lost")
			case -1003: return .localized("Server not found")
			case -1004: return .localized("Cannot connect to server")
			case -1200: return .localized("Secure connection failed")
			case -1201: return .localized("Server certificate expired")
			case -1202, -1203: return .localized("Server certificate untrusted")
			default: break
			}
		}
		let code = (error as? IDeviceSwiftError).map { Int($0.code) }
			?? (ns.domain == NSURLErrorDomain ? ns.code : nil)
		return text(message: error.localizedDescription, stage: stage, code: code)
	}

	static func text(message: String, stage: Stage, code: Int? = nil) -> String {
		let lower = message.lowercased()
		// Match specific causes before wrappers such as AFC/Installation Proxy.
		let causes: [([String], String)] = [
			(["ios interrupted background installation"], "iOS interrupted background installation"),
			(["0xe8008016", "invalid entitlements", "entitlements are not valid"], "Invalid app entitlements"),
			(["0xe8008015", "valid provisioning profile for this executable was not found"], "No matching provisioning profile"),
			(["0xe8008018", "identity used to sign the executable is no longer valid"], "Signing identity is invalid"),
			(["applicationverificationfailed", "failed to verify code signature", "signature verification failed"], "App verification failed"),
			(["device is locked", "devicelocked", "passwordprotected"], "Unlock device to install"),
			(["not enough free space", "no space left", "insufficient storage", "not enough storage"], "Not enough storage"),
			(["profile has expired", "profile expired"], "Provisioning profile expired"),
			(["certificate has expired", "certificate expired"], "Signing certificate expired"),
			(["certificate has been revoked", "certificate revoked"], "Signing certificate revoked"),
			(["minimumosversion", "requires a newer version of ios"], "Requires newer iOS"),
			(["unsupported architecture", "incompatible architecture"], "Unsupported architecture"),
			(["does not contain a payload"], "IPA has no Payload folder"),
			(["does not contain an application bundle"], "IPA has no app bundle"),
			(["archive entry escapes", "invalid archive", "invalid zip", "corrupt archive"], "Invalid app archive"),
			(["timed out", "timeout"], "Connection timed out"),
			(["internet connection appears to be offline", "not connected to the internet"], "No internet connection"),
			(["network connection was lost", "connection reset", "broken pipe"], "Connection lost"),
			(["could not connect to afc"], "Payload connection failed"),
			(["could not connect to installation proxy"], "Install service unavailable"),
			(["pairing file is missing"], "Pairing file missing"),
			(["pairing file is invalid", "invalidhostid"], "Pairing file invalid"),
			(["device tunnel unavailable", "rsd tunnel is unavailable"], "Device tunnel unavailable"),
			(["unable to start the local install server"], "Install server failed to start")
		]
		if let cause = causes.first(where: { $0.0.contains(where: lower.contains) }) { return .localized(cause.1) }
		if let regex = try? NSRegularExpression(pattern: #"HTTP\s+(\d{3})\b"#, options: .caseInsensitive),
			let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
			let range = Range(match.range(at: 1), in: message) {
			return "HTTP \(message[range])"
		}
		let clean = message.trimmingCharacters(in: .whitespacesAndNewlines)
		if !clean.isEmpty, clean.count <= 34, !clean.contains(where: { $0.isNewline }) { return clean }
		// Unknown native failures retain their code; never guess a cause or show
		// arbitrary shortened fragments of paths / nested technical descriptions.
		if let code, code != 0 { return "\(stage.label) \(String.localized("error")) (\(code))" }
		return "\(stage.label) \(String.localized("failed"))"
	}
}
