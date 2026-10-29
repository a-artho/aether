//
//  VersionHistoryView.swift
//  Aether
//
//  Created by Nagata Asami on 27/7/25.
//

import SwiftUI
import AltSourceKit

// MARK: - VersionHistoryView
struct VersionHistoryView: View {
	@Environment(\.dismiss) var dismiss
	
	let sourceURL: URL?
	let source: ASRepository
	let app: ASRepository.App
	let versions: [ASRepository.App.Version]
    
	var body: some View {
		ScrollView {
			LazyVStack(spacing: 12) {
				ForEach(SourceAppVersionEntry.entries(for: versions)) { entry in
					let version = entry.version
					AppVersionInfo(
						version: version.version,
						date: version.date?.date,
						description: version.localizedDescription ?? .localized("No release notes available")
					)
					.padding(.horizontal)
					.background(Color(.systemBackground))
					.contextMenu {
						if let downloadURL = version.downloadURL {
							Button {
								Task {
									_ = await DownloadManager.shared.startDownload(
										from: downloadURL,
										id: app.currentUniqueId,
										sourceProvenance: SourceAppProvenance(
											sourceURL: sourceURL,
											repository: source,
											app: app,
											version: version
										)
									)
								}
								dismiss()
							} label: {
								Label(version.version, systemImage: "arrow.down")
							}
                            
							Button {
								UIPasteboard.general.string = downloadURL.absoluteString
							} label: {
								Label(.localized("Copy Download URL"), systemImage: "doc.on.clipboard")
							}
						}
					}
                    
					Divider().padding(.horizontal)
				}
			}
			.padding(.top, 8)
		}
		.aetherAmbientBackground()
	}
}

/// View identity includes the artifact and disambiguates exact duplicates without
/// changing the model's version/build comparison semantics.
struct SourceAppVersionEntry: Identifiable {
	struct Identity: Hashable {
		let version: String
		let build: String?
		let downloadURL: URL?
	}
	struct ID: Hashable {
		let identity: Identity
		let occurrence: Int
	}
	let id: ID
	let version: ASRepository.App.Version

	static func entries(for versions: [ASRepository.App.Version]) -> [Self] {
		var occurrences: [Identity: Int] = [:]
		return versions.map { version in
			let identity = Identity(version: version.version, build: version.build, downloadURL: version.downloadURL)
			let occurrence = occurrences[identity, default: 0]
			occurrences[identity] = occurrence + 1
			return Self(id: ID(identity: identity, occurrence: occurrence), version: version)
		}
	}
}
