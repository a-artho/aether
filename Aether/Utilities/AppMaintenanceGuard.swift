import Foundation

/// Rechecked on the main actor immediately before mutations, not only by disabled UI.
@MainActor
enum AppMaintenanceGuard {
	private(set) static var isResetting = false

	static func beginReset() -> Bool {
		guard resetBlockReason == nil else { return false }
		isResetting = true
		return true
	}
	static var deviceOperationBlockReason: String? {
		if isResetting { return .localized("Wait for the reset to finish.") }
		let installations = AppInstallationManager.shared
		if installations.hasPendingInstalls || installations.hasRetiringWork || !installations.uninstallingBundleIdentifiers.isEmpty {
			return .localized("Finish or cancel installation work before changing pairing or resetting data.")
		}
		if UserDefaults.standard.bool(forKey: "Aether.spoofing.simulationMayBeActive") {
			return .localized("Stop location spoofing before changing pairing or resetting data.")
		}
		return nil
	}

	static var pairingBlockReason: String? {
		if let reason = deviceOperationBlockReason { return reason }
		return OnDevicePairingManager.shared.isActive ? .localized("Finish or cancel on-device pairing first.") : nil
	}

	static var resetBlockReason: String? {
		if let reason = pairingBlockReason { return reason }
		if DownloadManager.shared.hasActiveWork || ExportManager.shared.hasActiveWork || LibraryArtifactAccess.shared.hasReaders {
			return .localized("Finish or cancel imports, downloads, and exports before resetting data.")
		}
		return nil
	}

	@discardableResult
	static func allowPairingChange() -> Bool {
		guard let reason = pairingBlockReason else { return true }
		DebugLogManager.shared.log(reason, category: "Pairing", level: .notice)
		return false
	}
}
