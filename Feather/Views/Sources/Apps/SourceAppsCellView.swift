//
//  SourceAppsCellView.swift
//  Feather
//
//  Created by samara on 3.05.2025.
//

import SwiftUI
import AltSourceKit
import NimbleViews
import Combine
import NukeUI

// thats a whole pharaghraph of codes
struct SourceAppsCellView: View {
	@AppStorage("Feather.storeCellAppearance") private var _storeCellAppearance: Int = 0
	
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
						LazyImage(url: iconURL) { state in
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
				let desc = app.localizedDescription
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
				HStack(spacing: 3) {
					Image(systemName: "tag")
						.font(.caption2.weight(.medium))
						.foregroundStyle(Color.blue)
					Text(version)
						.foregroundStyle(.secondary)
				}
			}
		} else {
			HStack(spacing: 4) {
				if let version = app.currentVersion, !version.isEmpty {
					HStack(spacing: 3) {
						Image(systemName: "tag")
							.font(.caption2.weight(.medium))
							.foregroundStyle(Color.blue)
						Text(version)
					}
					.layoutPriority(1)
				}

				let rawSubtitle = app.currentDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
				if let rawSubtitle, !rawSubtitle.isEmpty {
					let cleanSubtitle = rawSubtitle.replacingOccurrences(of: "\n", with: " ")
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
