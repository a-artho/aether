//
//  Storage+Signed.swift
//  Feather
//
//  Created by samara on 17.04.2025.
//

import CoreData
import UIKit.UIImpactFeedbackGenerator

// MARK: - Class extension: Signed Apps
extension Storage {
	@MainActor
	func addSigned(
		uuid: String,
		source: URL? = nil,
		certificateUUID: String? = nil,
		
		appName: String? = nil,
		appIdentifier: String? = nil,
		appVersion: String? = nil,
		appIcon: String? = nil
	) throws {
		let new = Signed(context: context)
		
		new.uuid = uuid
		new.source = source
		new.date = Date()
		// if nil, we assume adhoc or certificate was deleted afterwards
		if let certificateUUID {
			let request: NSFetchRequest<CertificatePair> = CertificatePair.fetchRequest()
			request.fetchLimit = 1
			request.predicate = NSPredicate(format: "uuid == %@", certificateUUID)
			new.certificate = try context.fetch(request).first
		}
		// could possibly be nil, but thats fine.
		new.identifier = appIdentifier
		new.name = appName
		new.icon = appIcon
		new.version = appVersion
		
		if context.hasChanges {
			try context.save()
		}
		UIImpactFeedbackGenerator(style: .light).impactOccurred()
	}

	@MainActor
	func signedApp(uuid: String) -> Signed? {
		let request: NSFetchRequest<Signed> = Signed.fetchRequest()
		request.fetchLimit = 1
		request.predicate = NSPredicate(format: "uuid == %@", uuid)
		return try? context.fetch(request).first
	}
}
