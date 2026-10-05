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
	var showsDownloadButton: Bool = true
	var onSelect: (() -> Void)? = nil
	
	var body: some View {
		VStack {
			HStack(spacing: 18) {
				_selectableContent {
					_appDetails
				}
				if showsDownloadButton {
					DownloadButtonView(sourceURL: sourceURL, source: source, app: app)
				}
			}
			
			if
				_storeCellAppearance != 0,
				let desc = SourceAppBodyText.body(in: app.localizedDescription)
			{
				_selectableContent {
					Text(desc)
						.frame(maxWidth: .infinity, alignment: .leading)
						.font(.subheadline)
						.foregroundStyle(.secondary)
						.padding(.top, 2)
				}
			}
		}
	}

	/// Keep the navigation target separate from the download control, including
	/// in large-description mode.
	@ViewBuilder
	private func _selectableContent<Content: View>(@ViewBuilder content: () -> Content) -> some View {
		if let onSelect {
			Button(action: onSelect) {
				content().contentShape(Rectangle())
			}
			.buttonStyle(.plain)
		} else {
			content()
		}
	}

	private var _appDetails: some View {
		FRIconCellView(title: app.currentName, iconUrl: app.iconURL) {
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
	}

	@ViewBuilder
	private func _subtitleView() -> some View {
		let version = app.currentVersion.flatMap { $0.isEmpty ? nil : $0 }

		VStack(alignment: .leading, spacing: 2) {
			if let version {
				Text(version)
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}

			if _storeCellAppearance == 0 {
				if let description = SourceAppBodyText.subtitle(in: app.currentDescription, followingVersion: false) {
					Text(description)
						.font(.footnote)
						.foregroundStyle(.secondary)
						.lineLimit(1)
				} else if version == nil {
					Text(.localized("An awesome application"))
						.font(.footnote)
						.foregroundStyle(.secondary)
						.lineLimit(1)
				}
			}
		}
	}
}
