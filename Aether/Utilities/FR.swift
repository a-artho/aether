//
//  FR.swift
//  Aether
//
//  Created by samara on 22.04.2025.
//

import Foundation.NSURL
import UIKit.UIImage
import ZsignC
import AltSourceKit
import IDeviceSwift

private actor PackageProcessingGate {
	private var isOccupied = false
	private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []

	func tryAcquire() throws -> Bool {
		try Task.checkCancellation()
		guard !isOccupied else { return false }
		isOccupied = true
		return true
	}

	func acquire() async throws {
		try Task.checkCancellation()
		if !isOccupied {
			isOccupied = true
			return
		}
		let id = UUID()
		try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
				if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
				else { waiters.append((id, continuation)) }
			}
		} onCancel: {
			Task { await self.cancelWaiter(id) }
		}
	}

	private func cancelWaiter(_ id: UUID) {
		guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
		waiters.remove(at: index).1.resume(throwing: CancellationError())
	}

	func release() {
		if waiters.isEmpty {
			isOccupied = false
		} else {
			waiters.removeFirst().1.resume()
		}
	}
}

@MainActor
enum FR {
	nonisolated private static let packageProcessingGate = PackageProcessingGate()

	static func recoverPackageImport(
		download: Download,
		completion: @escaping @MainActor @Sendable (Result<Bool, Error>) -> Void
	) {
		Task.detached {
			let handler = await AppFileHandler(
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
		beginProcessing: @escaping @MainActor @Sendable () -> Bool = { true },
		waitingForProcessing: @escaping @MainActor @Sendable () -> Void = {},
		completion: @escaping @MainActor @Sendable (Error?) -> Void
	) -> Task<Void, Never> {
		Task.detached(priority: .utility) {
			let diagnosticID = transactionIdentifier ?? download?.importIdentifier ?? UUID().uuidString
			let diagnosticsEnabled = await MainActor.run { DebugLogManager.shared.isLoggingEnabled }
			let started = Date()
			var stage = "processing queue"
			func log(_ message: String, level: DebugLogItem.Level = .info) async {
				guard diagnosticsEnabled else { return }
				await MainActor.run {
					DebugLogManager.shared.log("[\(diagnosticID)] \(message); elapsed=\(Date().timeIntervalSince(started)), appState=\(UIApplication.shared.applicationState.rawValue).", category: "Import", level: level)
				}
			}
			await log("Import requested: \(ipa.lastPathComponent); waiting for processing queue")
			do {
				if try await !packageProcessingGate.tryAcquire() {
					await waitingForProcessing()
					try await packageProcessingGate.acquire()
				}
			} catch {
				let detail = error as NSError
				await log("Import failed at \(stage): domain=\(detail.domain), code=\(detail.code), \(detail.localizedDescription)", level: .error)
				await MainActor.run { completion(error) }
				return
			}
			defer {
				Task { await packageProcessingGate.release() }
			}

			guard await beginProcessing() else {
				await MainActor.run { completion(CancellationError()) }
				return
			}
			let handler = await AppFileHandler(
				file: ipa,
				download: download,
				sourceProvenance: sourceProvenance,
				transactionIdentifier: transactionIdentifier
			)

			do {
				stage = "recovery"
				await log("Processing queue acquired; checking committed import")
				try Task.checkCancellation()
				if try await handler.recoverCommittedImport() {
					await MainActor.run {
						completion(nil)
					}
					return
				}
				stage = "prepare"
				await log("Preparing private working copy")
				try await handler.prepare(copySource: copySource)
				try Task.checkCancellation()
				stage = "extraction"
				await log("Starting extraction")
				try await handler.extract()
				try Task.checkCancellation()
				stage = "moving extracted app"
				await log("Starting moving extracted app")
				try await handler.move()
				try Task.checkCancellation()
				stage = "database commit"
				await log("Starting database commit")
				try await handler.addToDatabase()
				try? await handler.clean()
				await log("Import committed successfully")
				await MainActor.run {
					completion(nil)
				}
			} catch {
				let detail = error as NSError
				let underlying = detail.userInfo[NSUnderlyingErrorKey] as? NSError
				await log("Import failed at \(stage): domain=\(detail.domain), code=\(detail.code), \(detail.localizedDescription); underlying=\(underlying.map { "\($0.domain)/\($0.code): \($0.localizedDescription)" } ?? "none")", level: .error)
				try? await handler.clean()
				await log("Failed import working files cleaned up")
				await MainActor.run {
					completion(error)
				}
			}
		}
	}

	@MainActor
	@discardableResult
	static func signPackageFile(
		_ appSnapshot: AppSnapshot,
		using options: Options,
		iconData: Data?,
		certificate: SigningCertificateSnapshot?,
		resultRowID: String? = nil,
		progress: @escaping @MainActor @Sendable (Double) -> Void,
		completion: @escaping @MainActor @Sendable (Result<String, Error>) -> Void
	) -> Task<Void, Never> {
		let signingStartedAt = Date()
		DebugLogManager.shared.log("Signing started state=\(UIApplication.shared.applicationState.rawValue).", category: "Signing", level: .info)
		let progressPublisher = OperationProgressPublisher(publish: progress)
		return Task.detached {
			await withTaskCancellationHandler {
				defer { progressPublisher.cancel() }
				let handler = SigningHandler(app: appSnapshot, options: options)
				handler.appCertificate = certificate
				handler.appIconData = iconData
				let signedUUID = handler.signedUUID

				do {
					try Task.checkCancellation()
					let copyStartedAt = Date()
					await MainActor.run { DebugLogManager.shared.log("Signing stage=copy started.", category: "Signing", level: .info) }
					try await handler.copy()
					await MainActor.run {
						DebugLogManager.shared.log("Signing stage=copy completed seconds=\(Date().timeIntervalSince(copyStartedAt)).", category: "Signing", level: .info)
						progress(0.2)
					}
					try Task.checkCancellation()
					try await handler.modify(progress: progressPublisher.submit)
					try Task.checkCancellation()
					try? await handler.clean()
					try await handler.addToDatabase(rowID: resultRowID) {
						progressPublisher.cancel()
						progress(1)
						DebugLogManager.shared.log("Signing completed elapsed=\(Date().timeIntervalSince(signingStartedAt)) state=\(UIApplication.shared.applicationState.rawValue).", category: "Signing", level: .info)
						completion(.success(signedUUID))
					}
				} catch {
					progressPublisher.cancel()
					try? await handler.clean()
					await MainActor.run {
						if let signed = Storage.shared.signedApp(uuid: signedUUID) {
							Storage.shared.deleteApp(for: signed)
						} else {
							try? FileManager.default.removeFileIfNeeded(at: FileManager.default.signed(signedUUID))
						}
						DebugLogManager.shared.log("Signing stopped elapsed=\(Date().timeIntervalSince(signingStartedAt)) state=\(UIApplication.shared.applicationState.rawValue) cancelled=\(error is CancellationError) error=\(error.localizedDescription).", category: "Signing", level: .error)
						completion(.failure(error))
					}
				}
			} onCancel: { progressPublisher.cancel() }
		}
	}

	static func handleCertificateFiles(
		p12URL: URL,
		provisionURL: URL,
		p12Password: String,
		certificateName: String = "",
		isDefault: Bool = false,
		completion: @escaping @MainActor @Sendable (Error?) -> Void
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
		guard AppMaintenanceGuard.allowPairingChange() else { return }
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
	}

	@discardableResult
	static func handleSource(
		_ urlString: String,
		shouldCommit: @escaping @MainActor @Sendable () -> Bool = { true },
		completion: (@MainActor @Sendable (Bool) -> Void)? = nil
	) -> Task<Void, Never>? {
		var trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { completion?(false); return nil }
		if !trimmed.lowercased().hasPrefix("http://") && !trimmed.lowercased().hasPrefix("https://") {
			trimmed = "https://" + trimmed
		}
		guard let url = URL(string: trimmed) else {
			UIAlertController.showAlertWithOk(title: .localized("Error"), message: .localized("Invalid URL."))
			completion?(false)
			return nil
		}
		return Task { @MainActor in
			do {
				let snapshot = try await SourceRepositoryService.shared.fetch(from: url)
				guard !Task.isCancelled, shouldCommit() else { return }
				let id = snapshot.repository.id ?? url.absoluteString
				guard !Storage.shared.sourceExists(id) else {
					UIAlertController.showAlertWithOk(title: .localized("Error"), message: .localized("Repo already added."))
					completion?(false)
					return
				}
				// No suspension between the presentation guard and the durable commit.
				Storage.shared.addSource(url, repository: snapshot.repository, id: id) { error in
					if let error {
						UIAlertController.showAlertWithOk(title: .localized("Error"), message: error.localizedDescription)
						completion?(false)
					} else {
						SourcesViewModel.shared.cache(snapshot, forIdentifier: id)
						completion?(true)
					}
				}
			} catch {
				guard !Task.isCancelled, shouldCommit() else { return }
				UIAlertController.showAlertWithOk(title: .localized("Error"), message: error.localizedDescription)
				completion?(false)
			}
		}
	}

	private static func _exportCertificate(_ certificate: CertificatePair, using template: String) {
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

	static func exportCertificateAndOpenUrl(using template: String) {
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
					_exportCertificate(cert, using: template)
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
