//
//  Storage+Sources.swift
//  Aether
//
//  Created by samara on 12.04.2025.
//

import CoreData
import AltSourceKit
import OSLog
import UIKit.UIImpactFeedbackGenerator

// MARK: - Class extension: Sources
extension Storage {
	/// Retrieve sources in an array, we don't normally need this in swiftUI but we have it for the copy sources action
	func getSources() -> [AltSource] {
		let request: NSFetchRequest<AltSource> = AltSource.fetchRequest()
		return (try? context.fetch(request)) ?? []
	}
	
	func addSource(
		_ url: URL,
		name: String? = "Unknown",
		identifier: String,
		iconURL: URL? = nil,
		deferSave: Bool = false,
		completion: @escaping (Error?) -> Void
	) {
		if sourceExists(identifier) {
			completion(nil)
			Logger.misc.debug("ignoring \(identifier)")
			return
		}
		
		let new = AltSource(context: context)
		new.name = name
		new.date = Date()
		new.identifier = identifier
		new.sourceURL = url
		new.iconURL = iconURL
		
		do {
			if !deferSave {
				try context.save()
				HapticManager.shared.impact()
			}
			completion(nil)
		} catch {
			completion(error)
		}
	}
	
	func addSource(
		_ url: URL,
		repository: ASRepository,
		id: String = "",
		deferSave: Bool = false,
		completion: @escaping (Error?) -> Void
	) {
		addSource(
			url,
			name: repository.name,
			identifier: !id.isEmpty
				? id
				: (repository.id ?? url.absoluteString),
			iconURL: repository.currentIconURL,
			deferSave: deferSave,
			completion: completion
		)
	}

	func addSources(
		repos: [URL: ASRepository],
		completion: @escaping (Error?) -> Void
	) {
		guard !repos.isEmpty else {
			completion(NSError(
				domain: "com.anfear.aether.sources",
				code: 1,
				userInfo: [NSLocalizedDescriptionKey: "No sources could be imported."]
			))
			return
		}

		for (url, repo) in repos {
			let identifier = repo.id ?? url.absoluteString
			guard !sourceExists(identifier) else {
				Logger.misc.debug("ignoring \(identifier)")
				continue
			}

			let new = AltSource(context: context)
			new.name = repo.name
			new.date = Date()
			new.identifier = identifier
			new.sourceURL = url
			new.iconURL = repo.currentIconURL
		}

		if let error = saveContext() {
			completion(error)
			return
		}
		HapticManager.shared.impact()
		completion(nil)
	}

	@MainActor
	func deleteSource(for source: AltSource) {
		let key = source.objectID.uriRepresentation().absoluteString
		let url = source.sourceURL
		context.delete(source)
		guard saveContext() == nil else { return }
		SourcesViewModel.shared.removeSource(key: key, url: url,
			evictURL: !getSources().contains { $0.sourceURL == url })
	}

	func sourceExists(_ identifier: String) -> Bool {
		let fetchRequest: NSFetchRequest<AltSource> = AltSource.fetchRequest()
		fetchRequest.predicate = NSPredicate(format: "identifier == %@", identifier)

		do {
			let count = try context.count(for: fetchRequest)
			return count > 0
		} catch {
			Logger.misc.error("Error checking if repository exists: \(error)")
			return false
		}
	}
}
