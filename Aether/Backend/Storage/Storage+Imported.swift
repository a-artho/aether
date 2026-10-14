//
//  Storage+Imported.swift
//  Aether
//
//  Created by samara on 11.04.2025.
//

import CoreData

// MARK: - Class extension: Imported Apps
extension Storage {

	@MainActor
	func upsertImported(
		uuid: String,
		source: URL? = nil,
		appName: String? = nil,
		appIdentifier: String? = nil,
		appVersion: String? = nil,
		appIcon: String? = nil
	) throws {
		let request: NSFetchRequest<Imported> = Imported.fetchRequest()
		request.predicate = NSPredicate(format: "uuid == %@", uuid)
		let matches = try context.fetch(request)
		let imported = matches.first ?? Imported(context: context)
		for duplicate in matches.dropFirst() {
			context.delete(duplicate)
		}

		imported.uuid = uuid
		imported.source = source
		imported.date = imported.date ?? Date()
		imported.identifier = appIdentifier
		imported.name = appName
		imported.icon = appIcon
		imported.version = appVersion

		if context.hasChanges {
			try context.save()
		}
	}

	@MainActor
	func importedExists(uuid: String) throws -> Bool {
		let request: NSFetchRequest<Imported> = Imported.fetchRequest()
		request.fetchLimit = 1
		request.predicate = NSPredicate(format: "uuid == %@", uuid)
		return try context.count(for: request) > 0
	}

	@MainActor
	func removeImported(uuid: String) throws {
		let importedRequest: NSFetchRequest<Imported> = Imported.fetchRequest()
		importedRequest.predicate = NSPredicate(format: "uuid == %@", uuid)
		try context.fetch(importedRequest).forEach(context.delete)

		let metadataRequest: NSFetchRequest<AppSourceMetadata> = AppSourceMetadata.fetchRequest()
		metadataRequest.predicate = NSPredicate(format: "appUUID == %@", uuid)
		try context.fetch(metadataRequest).forEach(context.delete)

		if context.hasChanges {
			try context.save()
		}
		LibraryArtifactIndex.shared.remove(uuid: uuid, isSigned: false)
	}
}
