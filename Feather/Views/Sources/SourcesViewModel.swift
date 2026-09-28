//
//  SourcesViewModel.swift
//  Feather
//
//  Created by samara on 30.04.2025.
//

import Foundation
import AltSourceKit
import SwiftUI
import NimbleJSON

// MARK: - Class
@MainActor
final class SourcesViewModel: ObservableObject {
	static let shared = SourcesViewModel()
	
	typealias RepositoryDataHandler = Result<ASRepository, Error>
	
	private let _dataService = NBFetchService()
	
	@Published private(set) var isFinished = true
	@Published private(set) var sources: [String: ASRepository] = [:]

	private struct SourceRequest: Sendable {
		let key: String
		let sourceURL: URL?
	}

	func repository(for source: AltSource) -> ASRepository? {
		sources[source.objectID.uriRepresentation().absoluteString]
	}
	
	func fetchSources(_ sources: FetchedResults<AltSource>, refresh: Bool = false, batchSize: Int = 4) async {
		guard isFinished else { return }
		
		// check if sources to be fetched are the same as before, if yes, return
		// also skip check if refresh is true
		if !refresh, sources.allSatisfy({ self.repository(for: $0) != nil }) { return }
		
		// isfinished is used to prevent multiple fetches at the same time
		isFinished = false
		defer { isFinished = true }
		
		self.sources = [:]
		let sourcesArray = sources.map {
			SourceRequest(
				key: $0.objectID.uriRepresentation().absoluteString,
				sourceURL: $0.sourceURL
			)
		}
		let dataService = _dataService
		
		for startIndex in stride(from: 0, to: sourcesArray.count, by: batchSize) {
			let endIndex = min(startIndex + batchSize, sourcesArray.count)
			let batch = sourcesArray[startIndex..<endIndex]
			
			let batchResults = await withTaskGroup(of: (String, ASRepository?).self, returning: [String: ASRepository].self) { group in
				for source in batch {
					group.addTask {
						guard let url = source.sourceURL else {
							return (source.key, nil)
						}
						
						return await withCheckedContinuation { continuation in
							dataService.fetch(from: url) { (result: RepositoryDataHandler) in
								switch result {
								case .success(let repo):
									continuation.resume(returning: (source.key, repo))
								case .failure(_):
									continuation.resume(returning: (source.key, nil))
								}
							}
						}
					}
				}
				
				var results = [String: ASRepository]()
				for await (source, repo) in group {
					if let repo {
						results[source] = repo
					}
				}
				return results
			}
			
			for (source, repo) in batchResults {
				self.sources[source] = repo
			}
		}
	}
}
