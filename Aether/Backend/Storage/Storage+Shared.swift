//
//  Storage+Shared.swift
//  Aether
//
//  Created by samara on 17.04.2025.
//

import CoreData

// MARK: - Class extension: Apps (Shared)
extension Storage {
	func getUuidDirectory(for app: AppInfoPresentable) -> URL? {
		guard let uuid = app.uuid else { return nil }
		return app.isSigned
			? FileManager.default.signed(uuid)
			: FileManager.default.unsigned(uuid)
	}
	
	func getAppDirectory(for app: AppInfoPresentable) -> URL? {
		guard let url = getUuidDirectory(for: app) else { return nil }
		return FileManager.default.getPath(in: url, for: "app")
	}
	
	@MainActor
	@discardableResult
	func deleteApp(for app: AppInfoPresentable, stagedCleanup: ((URL) -> Void)? = nil) -> Bool {
		guard !LibraryArtifactAccess.shared.hasReaders(for: app),
			!AppInstallationManager.shared.containsInstallation(for: app),
			!DownloadManager.shared.usesLibraryArtifact(app),
			!ExportManager.shared.usesLibraryArtifact(app) else {
			DebugLogManager.shared.log("Kept app files required by an installation, import, or export.", category: "Library", level: .notice)
			return false
		}
		let deletedSnapshot = AppSnapshot(app)
		var movedDirectory: (original: URL, staged: URL)?
		var beganDeletion = false
		do {
			guard let uuid = app.uuid else { return false }
			// Flush existing edits first: rollback below must affect only this deletion.
			if let error = saveContext() { throw error }
			let request = NSFetchRequest<NSManagedObject>(entityName: app.isSigned ? "Signed" : "Imported")
			request.predicate = NSPredicate(format: "uuid == %@", uuid)
			let objects = try context.fetch(request)
			if let url = getUuidDirectory(for: app), FileManager.default.fileExists(atPath: url.path) {
				let staged = url.deletingLastPathComponent().appendingPathComponent(".deleting-" + UUID().uuidString)
				try FileManager.default.moveItem(at: url, to: staged)
				movedDirectory = (url, staged)
			}
			beganDeletion = true
			try deleteSourceMetadata(for: uuid, deferSave: true)
			objects.forEach(context.delete)
			if let error = saveContext() { throw error }
			LibraryArtifactIndex.shared.remove(uuid: uuid, isSigned: app.isSigned)
		} catch {
			if beganDeletion { context.rollback() }
			if let movedDirectory {
				do { try FileManager.default.moveItem(at: movedDirectory.staged, to: movedDirectory.original) }
				catch { DebugLogManager.shared.log("Could not restore app files after failed deletion: \(error.localizedDescription)", category: "Library", level: .error) }
			}
			DebugLogManager.shared.log("Could not delete app: \(error.localizedDescription)", category: "Library", level: .error)
			return false
		}
		AppInstallationManager.shared.forgetInstallation(of: deletedSnapshot)
		if let movedDirectory {
			if let stagedCleanup {
				stagedCleanup(movedDirectory.staged)
				return true
			}
			do { try FileManager.default.removeItem(at: movedDirectory.staged) }
			catch { DebugLogManager.shared.log("App deleted, but could not clean staged files: \(error.localizedDescription)", category: "Library", level: .error) }
		}
		return true
	}
	
	/// Commit deletion on the owning context, then remove the staged app folder
	/// off the main actor. Only a value URL crosses into the file worker.
	@MainActor
	func deleteAppAsync(for app: AppInfoPresentable) async -> Bool {
		var stagedURL: URL?
		let deleted = deleteApp(for: app, stagedCleanup: { stagedURL = $0 })
		guard deleted, let stagedURL else { return deleted }
		let cleanupError = await Task.detached(priority: .utility) { () -> String? in
			do {
				try FileManager.default.removeItem(at: stagedURL)
				return nil
			} catch { return error.localizedDescription }
		}.value
		if let cleanupError {
			DebugLogManager.shared.log("App deleted, but could not clean staged files: \(cleanupError)", category: "Library", level: .error)
		}
		return true
	}

	func getCertificate(from app: AppInfoPresentable) -> CertificatePair? {
		if let signed = app as? Signed {
			return signed.certificate
		}
		return nil
	}
}

// MARK: - Helpers
/// A value-only description of an app for file workers. `Signed` and `Imported`
/// are main-context objects, so they must never outlive the main actor in a
/// detached signing, export, or installation task.
struct AppSnapshot: AppInfoPresentable, Sendable, Codable {
	let name: String?
	let version: String?
	let identifier: String?
	let date: Date?
	let icon: String?
	let uuid: String?
	let source: URL?
	let isSigned: Bool

	init(_ app: AppInfoPresentable) {
		name = app.name
		version = app.version
		identifier = app.identifier
		date = app.date
		icon = app.icon
		uuid = app.uuid
		source = app.source
		isSigned = app.isSigned
	}
}

/// The file-backed portion of a certificate needed by signing. Keeping this
/// separate from `CertificatePair` prevents a managed object from crossing a
/// detached worker boundary.
struct SigningCertificateSnapshot: Sendable {
	let uuid: String
	let password: String
	let certificateURL: URL
	let provisionURL: URL

	init?(_ certificate: CertificatePair?) {
		guard
			let certificate,
			let uuid = certificate.uuid,
			let certificateURL = FileManager.default.getPath(
				in: FileManager.default.certificates(uuid),
				for: Storage.FileRequest.certificate.rawValue
			),
			let provisionURL = FileManager.default.getPath(
				in: FileManager.default.certificates(uuid),
				for: Storage.FileRequest.provision.rawValue
			)
		else {
			return nil
		}

		self.uuid = uuid
		self.password = certificate.password ?? ""
		self.certificateURL = certificateURL
		self.provisionURL = provisionURL
	}
}

struct AnyApp: Identifiable {
	let base: AppInfoPresentable
	let id: String

	init(base: AppInfoPresentable) {
		self.base = base
		self.id = base.uuid ?? UUID().uuidString
	}
}

protocol AppInfoPresentable {
	var name: String? { get }
	var version: String? { get }
	var identifier: String? { get }
	var date: Date? { get }
	var icon: String? { get }
	var uuid: String? { get }
	var source: URL? { get }
	var isSigned: Bool { get }
	
}

extension Signed: AppInfoPresentable {
	var isSigned: Bool { true }
}

extension Imported: AppInfoPresentable {
	var isSigned: Bool { false }
}
