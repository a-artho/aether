//
//  SourceAppsCellView.swift
//  Aether
//
//  Created by samara on 3.05.2025.
//

import SwiftUI
import AltSourceKit
import NimbleViews
import Combine
import Nuke
import NukeUI

// thats a whole pharaghraph of codes
struct SourceAppsCellView: View {
	@Environment(\.displayScale) private var displayScale
	@AppStorage("Aether.storeCellAppearance") private var _storeCellAppearance: Int = 0
	
	let sourceURL: URL?
	let source: ASRepository
	let app: ASRepository.App
	var showSourceBadge: Bool = false
	
	var body: some View {
		VStack {
			HStack(spacing: 12) {
				FRIconCellView(
					title: app.currentName,
					iconUrl: app.iconURL
				) {
					_subtitleView()
				}
				.overlay(alignment: .bottomLeading) {
					if showSourceBadge, let iconURL = source.currentIconURL {
						LazyImage(request: ImageRequest(url: iconURL, userInfo: [
							.thumbnailKey: ImageRequest.ThumbnailOptions(maxPixelSize: Float(18 * displayScale))
						])) { state in
							if let image = state.image {
								image
									.appIconStyle(size: 18, isCircle: true, background: Color(uiColor: .secondarySystemBackground))
									.offset(x: 36, y: 4)
							}
						}
					}
				}
				DownloadButtonView(sourceURL: sourceURL, source: source, app: app)
			}
			
			if
				_storeCellAppearance != 0,
				let desc = SourceAppBodyText.body(in: app.localizedDescription)
			{
				Text(desc)
					.frame(maxWidth: .infinity, alignment: .leading)
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.padding(.top, 2)
			}
		}
	}

	@ViewBuilder
	private func _subtitleView() -> some View {
		let hasVersion = app.currentVersion != nil && !(app.currentVersion?.isEmpty ?? true)

		if _storeCellAppearance != 0 {
			if let version = app.currentVersion, !version.isEmpty {
				Text(version)
					.foregroundStyle(.secondary)
			}
		} else {
			HStack(spacing: 4) {
				if let version = app.currentVersion, !version.isEmpty {
					Text(version)
					.layoutPriority(1)
				}

				let rawSubtitle = SourceAppBodyText.subtitle(in: app.currentDescription, followingVersion: hasVersion)
				if let rawSubtitle, !rawSubtitle.isEmpty {
					let cleanSubtitle = rawSubtitle
					if hasVersion {
						Text("•")
							.font(.caption2)
							.foregroundStyle(Color.secondary.opacity(0.5))
					}
					Text(cleanSubtitle)
						.foregroundStyle(.secondary)
				} else if !hasVersion {
					Text(.localized("An awesome application"))
						.foregroundStyle(.secondary)
				}
			}
		}
	}
}
