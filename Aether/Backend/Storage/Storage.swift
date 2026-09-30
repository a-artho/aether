//
//  Persistence.swift
//  Aether
//
//  Created by samara on 10.04.2025.
//

import CoreData
import Foundation

// MARK: - Storage
final class Storage: ObservableObject {
	static let shared = Storage()
	let container: NSPersistentContainer
	
	private let _name: String = "Aether"

	init(inMemory: Bool = false) {
		container = NSPersistentContainer(name: _name)

		if inMemory {
			container.persistentStoreDescriptions.first?.url =
				URL(fileURLWithPath: "/dev/null")
		}
		
		container.persistentStoreDescriptions.first?.shouldMigrateStoreAutomatically = true
		container.persistentStoreDescriptions.first?.shouldInferMappingModelAutomatically = true

		_loadPersistentStoreAggressively()
		container.viewContext.automaticallyMergesChangesFromParent = true
		container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
	}

	var context: NSManagedObjectContext {
		container.viewContext
	}
	
	/// Performs a synchronous save on the view context. The old implementation
	/// queued the save onto the next run-loop turn, which allowed callers to
	/// report success before the object existed in the persistent store.
	@discardableResult
	func saveContext() -> Error? {
		var saveError: Error?
		context.performAndWait {
			guard self.context.hasChanges else { return }
			do {
				try self.context.save()
			} catch {
				saveError = error
			}
		}
		return saveError
	}
	
	func clearContext<T: NSManagedObject>(request: NSFetchRequest<T>) {
		guard let fetchRequest = request as? NSFetchRequest<NSFetchRequestResult> else { return }
		let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
		_ = try? context.execute(deleteRequest)
	}
	
	func countContent<T: NSManagedObject>(for type: T.Type) -> String {
		let request = T.fetchRequest()
		return "\((try? context.count(for: request)) ?? 0)"
	}

	private func _loadPersistentStoreAggressively() {
		container.loadPersistentStores { description, error in
			if let error {
				// Never destroy the user library as a side effect of a metadata
				// load failure. An explicit reset is the only operation allowed to
				// delete Signed, Unsigned, or Certificates.
				print("Aether could not load its metadata store at \(description.url?.path ?? "unknown location"): \(error.localizedDescription)")
			}
		}
	}
}
