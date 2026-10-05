//
//  FR.swift
//  Aether
//
//  Created by samara on 22.04.2025.
//

import Foundation.NSURL
import UIKit.UIImage
import ZsignC
import NimbleJSON
import AltSourceKit
import IDeviceSwift

private actor PackageProcessingGate {
	private var isOccupied = false
	private var waiters: [CheckedContinuation<Void, Never>] = []

	func acquire() async {
		if !isOccupied {
			isOccupied = true
			return
		}
		await withCheckedContinuation { waiters.append($0) }
	}

	func release() {
		if waiters.isEmpty {
			isOccupied = false
		} else {
			waiters.removeFirst().resume()
		}
	}
}

enum FR {
	private static let packageProcessingGate = PackageProcessingGate()

	static func recoverPackageImport(
		download: Download,
		completion: @escaping (Result<Bool, Error>) -> Void
	) {
		Task.detached {
			let handler = AppFileHandler(
				file: download.url,
				download: download,
				transactionIdentifier: download.importIdentifier
			)
		do {
				let recovered = try await handler.recoverCommittedImport()
				await MainActor.run {
					completion(.success(recovered))
				}
			} catch {
				await MainActor.run {
					completion(.failure(error))
				}
			}
		}
	}

	static func handlePackageFile(
		_ ipa: URL,
		download: Download? = nil,
		sourceProvenance: SourceAppProvenance? = nil,
		transactionIdentifier: String? = nil,
		copySource: Bool = true,
		completion: @escaping (Error?) -> Void
	) -> Task<Void, Never> {
		Task.detached(priority: .utility) {
			await packageProcessingGate.acquire()
			defer {
				Task { await packageProcessingGate.release() }
			}

			let handler = AppFileHandler(
				file: ipa,
				download: download,
				sourceProvenance: sourceProvenance,
				transactionIdentifier: transactionIdentifier
			)
			
			do {
				try Task.checkCancellation()
				if try await handler.recoverCommittedImport() {
					await MainActor.run {
						completion(nil)
					}
					return
				}
				try await handler.prepare(copySource: copySource)
				try Task.checkCancellation()
				try await handler.extract()
				try Task.checkCancellation()
				try await handler.move()
				try Task.checkCancellation()
				try await handler.addToDatabase()
				try? await handler.clean()
				await MainActor.run {
					completion(nil)
				}
			} catch {
				try? await handler.clean()
				await MainActor.run {
					completion(error)
				}
			}
		}
	}
	
	@MainActor
	@discardableResult
	static func signPackageFile(
		_ app: AppInfoPresentable,
		using options: Options,
		icon: UIImage?,
		certificate: CertificatePair?,
		completion: @escaping (Result<String, Error>) -> Void
	) -> Task<Void, Never> {
		let appSnapshot = AppSnapshot(app)
		let certificateSnapshot = SigningCertificateSnapshot(certificate)
		let iconData = icon?.pngData()
		let token = "signing-\(UUID().uuidString)"
		var worker: Task<Void, Never>?
		var backgroundObserver: NSObjectProtocol?
		#if !targetEnvironment(macCatalyst)
		let accepted = BackgroundTaskManager.shared.startWork(for: token,
			title: app.name ?? .localized("Signing App"), subtitle: .localized("Signing"), progress: 0, signing: true) {
			worker?.cancel()
		}
		if !accepted {
			backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
				object: nil, queue: .main) { _ in worker?.cancel() }
		}
		if !accepted, UIApplication.shared.applicationState != .active {
			completion(.failure(NSError(domain: "Aether.Background", code: 1,
				userInfo: [NSLocalizedDescriptionKey: String.localized("Open Aether to finish signing. Background execution is unavailable.")])))
			if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
			return Task {}
		}
		#endif
		let signingStartedAt = Date()
		#if !targetEnvironment(macCatalyst)
		DebugLogManager.shared.log("Signing execution granted=\(BackgroundTaskManager.shared.hasExecution(for: token)) continued=\(BackgroundTaskManager.shared.hasNativeTask(for: token)).", category: "Signing", level: .info)
		#endif
		DebugLogManager.shared.log("Signing started state=\(UIApplication.shared.applicationState.rawValue).", category: "Signing", level: .info)
		worker = Task.detached {
			let handler = SigningHandler(app: appSnapshot, options: options)
			handler.appCertificate = certificateSnapshot
			handler.appIconData = iconData
			
			do {
				try Task.checkCancellation()
				try await handler.copy()
				await MainActor.run {
					#if !targetEnvironment(macCatalyst)
					BackgroundTaskManager.shared.updateWork(for: token, title: appSnapshot.name ?? .localized("Signing App"), subtitle: .localized("Signing"), progress: 0.2)
					#endif
				}
				try Task.checkCancellation()
				try await handler.modify()
				try Task.checkCancellation()
				try? await handler.clean()
				await MainActor.run {
					#if !targetEnvironment(macCatalyst)
					BackgroundTaskManager.shared.stopTask(for: token, success: true)
					#endif
					if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
					DebugLogManager.shared.log("Signing completed elapsed=\(Date().timeIntervalSince(signingStartedAt)) state=\(UIApplication.shared.applicationState.rawValue).", category: "Signing", level: .info)
					completion(.success(handler.signedUUID))
				}
			} catch {
				try? await handler.clean()
				await MainActor.run {
					if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
					if let signed = Storage.shared.signedApp(uuid: handler.signedUUID) {
						Storage.shared.deleteApp(for: signed)
					} else {
						try? FileManager.default.removeFileIfNeeded(at: FileManager.default.signed(handler.signedUUID))
					}
					#if !targetEnvironment(macCatalyst)
					BackgroundTaskManager.shared.stopTask(for: token, success: false)
					#endif
					DebugLogManager.shared.log("Signing stopped elapsed=\(Date().timeIntervalSince(signingStartedAt)) state=\(UIApplication.shared.applicationState.rawValue) cancelled=\(error is CancellationError) error=\(error.localizedDescription).", category: "Signing", level: .error)
					completion(.failure(error))
				}
			}
		}
		return worker!
	}
	
	static func handleCertificateFiles(
		p12URL: URL,
		provisionURL: URL,
		p12Password: String,
		certificateName: String = "",
		isDefault: Bool = false,
		completion: @escaping (Error?) -> Void
	) {
		Task.detached {
			let handler = CertificateFileHandler(
				key: p12URL,
				provision: provisionURL,
				password: p12Password,
				nickname: certificateName.isEmpty ? nil : certificateName,
				isDefault: isDefault
			)
			
			do {
				try await handler.copy()
				try await handler.addToDatabase()
				await MainActor.run {
					completion(nil)
				}
			} catch {
				await MainActor.run {
					completion(error)
				}
			}
		}
	}
	
	static func checkPasswordForCertificate(
		for key: URL,
		with password: String,
		using provision: URL
	) -> Bool {
		defer {
			password_check_fix_free(provision.path)
		}
		
		password_check_fix(provision.path)
		
		if (!p12_password_check(key.path, password)) {
			return false
		}
		
		return true
	}
	
	static func movePairing(_ url: URL) {
		let fileManager = FileManager.default
		let dest = HeartbeatManager.importedPairingFileURL()
		let stagedImport = dest.deletingLastPathComponent()
			.appendingPathComponent(".pairing-import-\(UUID().uuidString)")

		do {
			try fileManager.createDirectory(
				at: dest.deletingLastPathComponent(),
				withIntermediateDirectories: true
			)
			try fileManager.copyItem(at: url, to: stagedImport)
			try fileManager.removeFileIfNeeded(at: dest)
			try fileManager.moveItem(at: stagedImport, to: dest)
			// Imported and on-device records are separate formats. Keep both, but
			// make this explicitly imported record the one used for future installs.
			HeartbeatManager.useImportedPairingFile()
		} catch {
			try? fileManager.removeItem(at: stagedImport)
			return
		}
		
		HeartbeatManager.shared.resetRSDTunnel()
		HeartbeatManager.shared.start(true)
	}
	
	static func downloadSSLCertificates(
		from urlString: String,
		completion: @escaping (Bool) -> Void
	) {
		NBFetchService().fetch(from: urlString) { (result: Result<ServerView.ServerPackModel, Error>) in
			switch result {
			case .success(let pack):
				do {
					try FileManager.forceWrite(content: pack.key, to: "server.pem")
					try FileManager.forceWrite(content: pack.cert, to: "server.crt")
					try FileManager.forceWrite(content: pack.info.domains.commonName, to: "commonName.txt")
					DispatchQueue.main.async {
						let generator = UINotificationFeedbackGenerator()
						generator.notificationOccurred(.success)
						completion(true)
					}
				} catch {
					DispatchQueue.main.async {
						completion(false)
					}
				}
			case .failure(_):
				DispatchQueue.main.async {
					completion(false)
				}
			}
		}
	}
	
	static func handleSource(
		_ urlString: String,
		completion: ((Bool) -> Void)? = nil
	) {
		var trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else {
			completion?(false)
			return
		}
		
		if !trimmed.lowercased().hasPrefix("http://") && !trimmed.lowercased().hasPrefix("https://") {
			trimmed = "https://" + trimmed
		}
		
		guard let url = URL(string: trimmed) else {
			DispatchQueue.main.async {
				UIAlertController.showAlertWithOk(title: .localized("Error"), message: .localized("Invalid URL."))
				completion?(false)
			}
			return
		}
		
		Task {
			do {
				let snapshot = try await SourceRepositoryService.shared.fetch(from: url)
				let data = snapshot.repository
				let id = data.id ?? url.absoluteString

				DispatchQueue.main.async {
					if !Storage.shared.sourceExists(id) {
						Storage.shared.addSource(url, repository: data, id: id) { error in
							if let error = error {
								UIAlertController.showAlertWithOk(title: .localized("Error"), message: error.localizedDescription)
								completion?(false)
							} else {
								Task { @MainActor in
									SourcesViewModel.shared.cache(data, forIdentifier: id)
									completion?(true)
								}
							}
						}
					} else {
						UIAlertController.showAlertWithOk(title: .localized("Error"), message: .localized("Repo already added."))
						completion?(false)
					}
				}
			} catch {
				DispatchQueue.main.async {
					UIAlertController.showAlertWithOk(title: .localized("Error"), message: error.localizedDescription)
					completion?(false)
				}
			}
		}
	}
	
	static func exportCertificateAndOpenUrl(using template: String) {
		// Helper that performs the export for a given certificate
		func performExport(for certificate: CertificatePair) {
			guard
				let certificateKeyFile = Storage.shared.getFile(.certificate, from: certificate),
				let certificateKeyFileData = try? Data(contentsOf: certificateKeyFile)
			else {
				return
			}
			
			let base64encodedCert = certificateKeyFileData.base64EncodedString()
			
			var allowedQueryParamAndKey = NSCharacterSet.urlQueryAllowed
			allowedQueryParamAndKey.remove(charactersIn: ";/?:@&=+$, ")
			
			guard let encodedCert = base64encodedCert.addingPercentEncoding(withAllowedCharacters: allowedQueryParamAndKey) else {
				return
			}
			
			let urlStr = template
				.replacingOccurrences(of: "$(BASE64_CERT)", with: encodedCert)
				.replacingOccurrences(of: "$(PASSWORD)", with: certificate.password ?? "")
			
			guard let callbackUrl = URL(string: urlStr) else {
				return
			}
			
			UIApplication.shared.open(callbackUrl)
		}
		
		let certificates = Storage.shared.getAllCertificates()
		guard !certificates.isEmpty else { return }
		
		DispatchQueue.main.async {
			var selectionActions: [UIAlertAction] = []
			
			for cert in certificates {
				var title: String
				let decoded = Storage.shared.getProvisionFileDecoded(for: cert)
				
				title = cert.nickname ?? decoded?.Name ?? .localized("Unknown")
				
				if let getTaskAllow = decoded?.Entitlements?["get-task-allow"]?.value as? Bool, getTaskAllow == true {
					title = "🐞 \(title)"
				}
				
				let selectAction = UIAlertAction(title: title, style: .default) { _ in
					performExport(for: cert)
				}
				selectionActions.append(selectAction)
			}
			
			UIAlertController.showAlertWithCancel(
				title: .localized("Export Certificate"),
				message: .localized("Do you want to export your certificate to an external app? That app will be able to sign apps using your certificate."),
				style: .alert,
				actions: selectionActions
			)
		}
	}
}
