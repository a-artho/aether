//
//  Storage+Certificate.swift
//  Aether
//
//  Created by samara on 16.04.2025.
//

import CoreData
import Zsign

// MARK: - Class extension: certificate
extension Storage {
	@MainActor
	func addCertificate(
		uuid: String,
		password: String? = nil,
		nickname: String? = nil,
		ppq: Bool = false,
		expiration: Date,
		isDefault: Bool = false
	) throws {
		let new = CertificatePair(context: context)
		new.uuid = uuid
		new.date = Date()
		new.password = password
		new.ppQCheck = ppq
		new.expiration = expiration
		new.nickname = nickname
		new.isDefault = isDefault
		Storage.shared.revokagedCertificate(for: new)
		if let error = saveContext() {
			throw error
		}
		HapticManager.shared.impact()
	}
	
	func deleteCertificate(for cert: CertificatePair) {
		if let uuid = cert.uuid {
			Self._provisionLock.lock()
			Self._provisionCache.removeValue(forKey: uuid)
			Self._provisionLock.unlock()
		}
		if let url = getUuidDirectory(for: cert) {
			try? FileManager.default.removeItem(at: url)
		}
		context.delete(cert)
		saveContext()
	}
	
	func getCertificate(for index: Int) -> CertificatePair? {
		let fetchRequest: NSFetchRequest<CertificatePair> = CertificatePair.fetchRequest()
		fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)]

		guard
			let results = try? context.fetch(fetchRequest),
			index >= 0 && index < results.count
		else {
			return nil
		}
		
		return results[index]
	}
	
	func revokagedCertificate(for cert: CertificatePair) {
		guard !cert.revoked else { return }
		
		guard let certificateUUID = cert.uuid else { return }
		Zsign.checkRevokage(
			provisionPath: Storage.shared.getFile(.provision, from: cert)?.path ?? "",
			p12Path: Storage.shared.getFile(.certificate, from: cert)?.path ?? "",
			p12Password: cert.password ?? ""
		) { [weak self] (status, _, _) in
			guard status == 1 else { return }
			Task { @MainActor [weak self] in
				guard let self, let certificate = self.getAllCertificates().first(where: { $0.uuid == certificateUUID }), !certificate.isDeleted, certificate.managedObjectContext === self.context else {
					DebugLogManager.shared.log("Ignored revocation result for a removed certificate.", category: "Certificate", level: .debug)
					return
				}
				certificate.revoked = true
				self.saveContext()
			}
		}
	}
	
	enum FileRequest: String {
		case certificate = "p12"
		case provision = "mobileprovision"
	}
	
	func getFile(_ type: FileRequest, from cert: CertificatePair) -> URL? {
		guard let url = getUuidDirectory(for: cert) else {
			return nil
		}
		
		return FileManager.default.getPath(in: url, for: type.rawValue)
	}
	
	private static var _provisionCache: [String: Certificate] = [:]
	private static let _provisionLock = NSLock()

	func getProvisionFileDecoded(for cert: CertificatePair) -> Certificate? {
		if let uuid = cert.uuid {
			Self._provisionLock.lock()
			if let cached = Self._provisionCache[uuid] {
				Self._provisionLock.unlock()
				return cached
			}
			Self._provisionLock.unlock()
		}

		guard let url = getFile(.provision, from: cert) else {
			return nil
		}
		
		let read = CertificateReader(url)
		if let decoded = read.decoded, let uuid = cert.uuid {
			Self._provisionLock.lock()
			Self._provisionCache[uuid] = decoded
			Self._provisionLock.unlock()
			return decoded
		}
		return read.decoded
	}
	
	func getUuidDirectory(for cert: CertificatePair) -> URL? {
		guard let uuid = cert.uuid else {
			return nil
		}
		
		return FileManager.default.certificates(uuid)
	}
	
	func getAllCertificates() -> [CertificatePair] {
		let fetchRequest: NSFetchRequest<CertificatePair> = CertificatePair.fetchRequest()
		fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)]
		return (try? context.fetch(fetchRequest)) ?? []
	}
}
