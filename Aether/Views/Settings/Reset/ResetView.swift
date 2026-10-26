//
//  ResetView.swift
//  Aether
//
//  Created by samara on 19.06.2025.
//

import SwiftUI
import NimbleViews
import Nuke
import CoreData
import IDeviceSwift

// MARK: - View
struct ResetView: View {
	@ObservedObject private var installations = AppInstallationManager.shared
	@ObservedObject private var downloads = DownloadManager.shared
	@ObservedObject private var exports = ExportManager.shared
	@ObservedObject private var pairing = OnDevicePairingManager.shared
	@ObservedObject private var ignoredUpdates = IgnoredAppUpdates.shared
	@State private var confirmsIgnoredUpdatesReset = false
	@AppStorage("Aether.spoofing.simulationMayBeActive") private var spoofingActive = false
	// MARK: Body
	var body: some View {
		NBList(.localized("Reset")) {
			_cache()
			Section {
				Button { confirmsIgnoredUpdatesReset = true } label: {
					SettingsRowLabel(.localized("Reset Ignored Updates"), systemImage: "arrow.counterclockwise", backgroundColor: .orange)
				}
				.disabled(ignoredUpdates.identifiers.isEmpty)
			}
			_installation()
			_coredata()
			_all()
			if let reason = AppMaintenanceGuard.resetBlockReason {
				Section { Text(reason).font(.footnote).foregroundStyle(.secondary) }
			}
		}
		.aetherAmbientScrollBackground(base: .grouped)
		.disabled(AppMaintenanceGuard.resetBlockReason != nil)
		.confirmationDialog(String.localized("Reset Ignored Updates?"), isPresented: $confirmsIgnoredUpdatesReset, titleVisibility: .visible) {
			Button(String.localized("Reset Ignored Updates"), role: .destructive) { ignoredUpdates.reset() }
			Button(String.localized("Cancel"), role: .cancel) {}
		} message: {
			Text(String.localized("Check for updates again for all ignored apps."))
		}
	}
	
	private func _cacheSize() -> String {
		var totalCacheSize = URLCache.shared.currentDiskUsage
		if let nukeCache = ImagePipeline.shared.configuration.dataCache as? DataCache {
			totalCacheSize += nukeCache.totalSize
		}
		return "\(ByteCountFormatter.string(fromByteCount: Int64(totalCacheSize), countStyle: .file))"
	}
	
	private static func _allowReset() -> Bool {
		guard let reason = AppMaintenanceGuard.resetBlockReason else { return true }
		DebugLogManager.shared.log("Reset blocked: \(reason)", category: "Reset", level: .notice)
		UIAlertController.showAlertWithOk(title: .localized("Work in Progress"), message: reason)
		return false
	}

	static func resetAlert(
		title: String,
		message: String = "",
		action: @escaping @MainActor () async -> Void
	) {
		guard _allowReset() else { return }
		let action = UIAlertAction(
			title: .localized("Proceed"),
			style: .destructive
		) { _ in
			Task { @MainActor in
				guard _allowReset(), AppMaintenanceGuard.beginReset() else { return }
				// Keep new work blocked until the scheduled restart exits this process.
				await action()
				UIApplication.shared.suspendAndReopen()
			}
		}
		
		let style: UIAlertController.Style = UIDevice.current.userInterfaceIdiom == .pad
			? .alert
			: .actionSheet
		
		var msg = ""
		if !message.isEmpty { msg = message + "\n" }
		msg.append(.localized("This action cannot be undone. Would you like to proceed?"))
	
		UIAlertController.showAlertWithCancel(
			title: title,
			message: msg,
			style: style,
			actions: [action]
		)
	}
}

// MARK: - View extension
extension ResetView {
	@ViewBuilder
	private func _cache() -> some View {
		Section {
			Button {
				Self.resetAlert(title: .localized("Reset Work Cache")) {
					await Self.clearDownloadRecovery()
					Self.clearWorkCache()
				}
			} label: {
				SettingsRowLabel(.localized("Reset Work Cache"), systemImage: "xmark.bin.fill", backgroundColor: .orange)
			}
			
			Button {
				Self.resetAlert(
					title: .localized("Reset Network Cache"),
					message: _cacheSize()
				) {
					await Self.clearNetworkCache()
				}
			} label: {
				SettingsRowLabel(.localized("Reset Network Cache"), systemImage: "network", backgroundColor: .orange)
			}
		}
	}
	
	@ViewBuilder
	private func _installation() -> some View {
		Section {
			Button {
				Self.resetAlert(title: .localized("Reset Pairing")) {
					Self.resetPairing()
				}
			} label: {
				SettingsRowLabel(.localized("Reset Pairing"), systemImage: "key.fill", backgroundColor: .purple)
			}
			
			Button {
				Self.resetAlert(title: .localized("Reset Tunneling")) {
					await Self.resetTunneling()
				}
			} label: {
				SettingsRowLabel(.localized("Reset Tunneling"), systemImage: "network", backgroundColor: .green)
			}
		}
	}

	@ViewBuilder
	private func _coredata() -> some View {
		Section {
			Button {
				Self.resetAlert(
					title: .localized("Reset Sources"),
					message: Self._formattedCount(for: AltSource.self, label: .localized("Sources"))
				) {
					Self.resetSources()
				}
			} label: {
				SettingsRowLabel(.localized("Reset Sources"), systemImage: "globe", backgroundColor: .red)
			}
			
			Button {
				Self.resetAlert(
					title: .localized("Reset Signed Apps"),
					message: Self._formattedCount(for: Signed.self, label: .localized("Signed Apps"))
				) {
					Self.deleteSignedApps()
				}
			} label: {
				SettingsRowLabel(.localized("Reset Signed Apps"), systemImage: "signature", backgroundColor: .red)
			}
			
			Button {
				Self.resetAlert(
					title: .localized("Reset Imported Apps"),
					message: Self._formattedCount(for: Imported.self, label: .localized("Imported Apps"))
				) {
					Self.deleteImportedApps()
				}
			} label: {
				SettingsRowLabel(.localized("Reset Imported Apps"), systemImage: "arrow.down.app.fill", backgroundColor: .red)
			}
			
			Button {
				Self.resetAlert(
					title: .localized("Reset Certificates"),
					message: Self._formattedCount(for: CertificatePair.self, label: .localized("Certificates"))
				) {
					Self.resetCertificates()
				}
			} label: {
				SettingsRowLabel(.localized("Reset Certificates"), systemImage: "checkmark.seal.fill", backgroundColor: .red)
			}
		}
	}
	
	@ViewBuilder
	private func _all() -> some View {
		Section {
			Button {
				Self.resetAlert(title: .localized("Reset Settings")) {
					Self.resetUserDefaults()
				}
			} label: {
				SettingsRowLabel(
					.localized("Reset Settings"),
					systemImage: "gearshape.fill",
					backgroundColor: .red,
					textColor: .red
				)
			}
			
			Button {
				Self.resetAlert(title: .localized("Reset All")) {
					await Self.resetAll()
				}
			} label: {
				SettingsRowLabel(
					.localized("Reset All"),
					systemImage: "trash.fill",
					backgroundColor: .red,
					textColor: .red
				)
			}
		}
	}

	private static func _formattedCount<T: NSManagedObject>(for type: T.Type, label: String) -> String {
		let count = Storage.shared.countContent(for: type)
		return "\(count) \(label)"
	}
}

// MARK: - View extension: reset
extension ResetView {
	private static func clearDownloadRecovery() async {
		do { try await DownloadManager.shared.clearRecoveryArtifacts() }
		catch { DebugLogManager.shared.log("Download recovery cleanup failed: \(error.localizedDescription)", category: "Reset", level: .error) }
	}

	static func clearWorkCache() {
		let fileManager = FileManager.default
		let tmpDirectory = fileManager.temporaryDirectory
		let aetherScratchPrefixes = [
			"AetherDownloads",
			"AetherImport_",
			"AetherInstall_",
			"AetherSigning_",
			"AetherTweak_"
		]

		guard let files = try? fileManager.contentsOfDirectory(
			at: tmpDirectory,
			includingPropertiesForKeys: nil
		) else { return }

		for file in files where aetherScratchPrefixes.contains(where: file.lastPathComponent.hasPrefix) {
			try? fileManager.removeItem(at: file)
		}
	}
	
	static func clearNetworkCache() async {
		await SourcesViewModel.shared.clearNetworkCache()
		URLCache.shared.removeAllCachedResponses()
		HTTPCookieStorage.shared.removeCookies(since: Date.distantPast)
		
		if let dataCache = ImagePipeline.shared.configuration.dataCache as? DataCache {
			dataCache.removeAll()
		}
		
		if let imageCache = ImagePipeline.shared.configuration.imageCache as? Nuke.ImageCache {
			imageCache.removeAll()
		}
	}
	
	static func resetSources() {
		Storage.shared.clearContext(request: AltSource.fetchRequest())
	}
	
	static func deleteSignedApps() {
		Storage.shared.deleteSourceMetadata(kind: .signed)
		Storage.shared.clearContext(request: Signed.fetchRequest())
		LibraryArtifactIndex.shared.resetSigned()
		try? FileManager.default.removeFileIfNeeded(at: FileManager.default.signed)
	}
	
	static func deleteImportedApps() {
		Storage.shared.deleteSourceMetadata(kind: .imported)
		Storage.shared.clearContext(request: Imported.fetchRequest())
		LibraryArtifactIndex.shared.resetImported()
		try? FileManager.default.removeFileIfNeeded(at: FileManager.default.unsigned)
	}
	
	static func resetPairing() {
		let fm = FileManager.default
		try? fm.removeItem(at: HeartbeatManager.importedPairingFileURL())
		try? fm.removeItem(at: HeartbeatManager.onDevicePairingFileURL())
		UserDefaults.standard.removeObject(forKey: "aether.activePairingRecordSource")
		HeartbeatManager.shared.resetRSDTunnel()
	}
	
	static func resetTunneling() async {
		await EmbeddedTunnelManager.shared.resetConfiguration()
		try? await EmbeddedTunnelManager.shared.resetNetworkConfiguration()
		UserDefaults.standard.removeObject(forKey: "Aether.tunnelMethod")
		UserDefaults.standard.removeObject(forKey: EmbeddedTunnelManager.interfaceAddressKey)
		UserDefaults.standard.removeObject(forKey: EmbeddedTunnelManager.peerAddressKey)
		UserDefaults.standard.removeObject(forKey: EmbeddedTunnelManager.allowIntermediateAddressesKey)
	}

	static func resetCertificates(resetAll: Bool = false) {
		if !resetAll { UserDefaults.standard.set(0, forKey: "aether.selectedCert") }
		Storage.shared.clearContext(request: CertificatePair.fetchRequest())
		try? FileManager.default.removeFileIfNeeded(at: FileManager.default.certificates)
	}
	
	static func resetUserDefaults() {
		UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
	}
	
	static func resetAll() async {
		await clearDownloadRecovery()
		clearWorkCache()
		await clearNetworkCache()
		resetPairing()
		await resetTunneling()
		resetSources()
		deleteSignedApps()
		deleteImportedApps()
		resetCertificates(resetAll: true)
		resetUserDefaults()
	}
}
