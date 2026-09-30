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
	
	func deleteApp(for app: AppInfoPresentable) {
		do {
			if let url = getUuidDirectory(for: app) {
				try? FileManager.default.removeItem(at: url)
			}
			deleteSourceMetadata(for: app.uuid)
			if let object = app as? NSManagedObject {
				context.delete(object)
			}
			saveContext()
		}
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
struct AppSnapshot: AppInfoPresentable, Sendable {
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
	
	var id: String {
		base.uuid ?? UUID().uuidString
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
