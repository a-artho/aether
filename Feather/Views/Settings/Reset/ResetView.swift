//
//  ResetView.swift
//  Feather
//
//  Created by samara on 19.06.2025.
//

import SwiftUI
import NimbleViews
import Nuke
import CoreData

// MARK: - View
struct ResetView: View {
	// MARK: Body
	var body: some View {
		NBList(.localized("Reset")) {
			_cache()
			_coredata()
			_all()
		}
	}
	
	private func _cacheSize() -> String {
		var totalCacheSize = URLCache.shared.currentDiskUsage
		if let nukeCache = ImagePipeline.shared.configuration.dataCache as? DataCache {
			totalCacheSize += nukeCache.totalSize
		}
		return "\(ByteCountFormatter.string(fromByteCount: Int64(totalCacheSize), countStyle: .file))"
	}
	
	static func resetAlert(
		title: String,
		message: String = "",
		action: @escaping () -> Void
	) {
		let action = UIAlertAction(
			title: .localized("Proceed"),
			style: .destructive
		) { _ in
			action()
			UIApplication.shared.suspendAndReopen()
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
					Self.clearNetworkCache()
				}
			} label: {
				SettingsRowLabel(.localized("Reset Network Cache"), systemImage: "network", backgroundColor: .orange)
			}
		}
	}
	
	@ViewBuilder
	private func _coredata() -> some View {
		Section {
			Button {
				Self.resetAlert(
					title: .localized("Reset Sources"),
					message: Storage.shared.countContent(for: AltSource.self)
				) {
					Self.resetSources()
				}
			} label: {
				SettingsRowLabel(.localized("Reset Sources"), systemImage: "globe", backgroundColor: .red)
			}
			
			Button {
				Self.resetAlert(
					title: .localized("Reset Signed Apps"),
					message: Storage.shared.countContent(for: Signed.self)
				) {
					Self.deleteSignedApps()
				}
			} label: {
				SettingsRowLabel(.localized("Reset Signed Apps"), systemImage: "signature", backgroundColor: .red)
			}
			
			Button {
				Self.resetAlert(
					title: .localized("Reset Imported Apps"),
					message: Storage.shared.countContent(for: Imported.self)
				) {
					Self.deleteImportedApps()
				}
			} label: {
				SettingsRowLabel(.localized("Reset Imported Apps"), systemImage: "arrow.down.app.fill", backgroundColor: .red)
			}
			
			Button {
				Self.resetAlert(
					title: .localized("Reset Certificates"),
					message: Storage.shared.countContent(for: CertificatePair.self)
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
				HStack(spacing: 12) {
					SettingsIconBadge(systemImage: "gearshape.fill", backgroundColor: .red)
					Text(.localized("Reset Settings"))
						.foregroundColor(.red)
				}
			}
			
			Button {
				Self.resetAlert(title: .localized("Reset All")) {
					Self.resetAll()
				}
			} label: {
				HStack(spacing: 12) {
					SettingsIconBadge(systemImage: "trash.fill", backgroundColor: .red)
					Text(.localized("Reset All"))
						.foregroundColor(.red)
				}
			}
		}
	}
}

// MARK: - View extension: reset
extension ResetView {
	static func clearWorkCache() {
		let fileManager = FileManager.default
		let tmpDirectory = fileManager.temporaryDirectory
		let featherScratchPrefixes = [
			"FeatherDownloads",
			"FeatherImport_",
			"FeatherInstall_",
			"FeatherSigning_",
			"FeatherTweak_"
		]

		guard let files = try? fileManager.contentsOfDirectory(
			at: tmpDirectory,
			includingPropertiesForKeys: nil
		) else { return }

		for file in files where featherScratchPrefixes.contains(where: file.lastPathComponent.hasPrefix) {
			try? fileManager.removeItem(at: file)
		}
	}
	
	static func clearNetworkCache() {
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
		try? FileManager.default.removeFileIfNeeded(at: FileManager.default.signed)
	}
	
	static func deleteImportedApps() {
		Storage.shared.deleteSourceMetadata(kind: .imported)
		Storage.shared.clearContext(request: Imported.fetchRequest())
		try? FileManager.default.removeFileIfNeeded(at: FileManager.default.unsigned)
	}
	
	static func resetCertificates(resetAll: Bool = false) {
		if !resetAll { UserDefaults.standard.set(0, forKey: "feather.selectedCert") }
		Storage.shared.clearContext(request: CertificatePair.fetchRequest())
		try? FileManager.default.removeFileIfNeeded(at: FileManager.default.certificates)
	}
	
	static func resetUserDefaults() {
		UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
	}
	
	static func resetAll() {
		clearWorkCache()
		clearNetworkCache()
		resetSources()
		deleteSignedApps()
		deleteImportedApps()
		resetCertificates(resetAll: true)
		resetUserDefaults()
	}
}
