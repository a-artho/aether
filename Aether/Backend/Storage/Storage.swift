//
//  Persistence.swift
//  Aether
//
//  Created by samara on 10.04.2025.
//

import CoreData
import Foundation

// MARK: - Storage
@MainActor
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

		container.persistentStoreDescriptions.first?.shouldMigrateStoreAutomatically = false
		container.persistentStoreDescriptions.first?.shouldInferMappingModelAutomatically = false

		_loadPersistentStoreAggressively()
		container.viewContext.automaticallyMergesChangesFromParent = true
		container.viewContext.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
	}

	var context: NSManagedObjectContext {
		container.viewContext
	}

	/// Performs a synchronous save on the view context. The old implementation
	/// queued the save onto the next run-loop turn, which allowed callers to
	/// report success before the object existed in the persistent store.
	@discardableResult
	func saveContext() -> Error? {
		guard context.hasChanges else { return nil }
		do { try context.save(); return nil }
		catch { return error }
	}

	func clearContext<T: NSManagedObject>(request: NSFetchRequest<T>) {
		guard let fetchRequest = request as? NSFetchRequest<NSFetchRequestResult> else { return }
		do {
			let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
			deleteRequest.resultType = .resultTypeObjectIDs
			let result = try context.execute(deleteRequest) as? NSBatchDeleteResult
			if let ids = result?.result as? [NSManagedObjectID] {
				NSManagedObjectContext.mergeChanges(
					fromRemoteContextSave: [NSDeletedObjectsKey: ids], into: [context]
				)
			}
		} catch {
			DebugLogManager.shared.log("Metadata reset failed: \(error.localizedDescription)", category: "Storage", level: .error)
		}
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
				DiagnosticLog.error("Could not load metadata store at \(description.url?.path ?? "unknown location"): \(error.localizedDescription)", category: "Storage")
			}
		}
	}
}
