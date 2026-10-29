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
	enum SelectionOwner {
		case swiftUIButton
		case tableView
	}

	@AppStorage("Aether.storeCellAppearance") private var _storeCellAppearance: Int = 0
	
	let sourceURL: URL?
	let source: ASRepository
	let app: ASRepository.App
	var showSourceBadge: Bool = false
	var showsDownloadButton: Bool = true
	var selectionOwner: SelectionOwner = .swiftUIButton
	var onSelect: (() -> Void)? = nil
	
	@ViewBuilder
	var body: some View {
		switch selectionOwner {
		case .tableView:
			_rowBody
		case .swiftUIButton:
			_rowBody.contextMenu {
				SourceDownloadAgainAction(sourceURL: sourceURL, source: source, app: app)
			}
		}
	}

	private var _rowBody: some View {
		VStack {
			HStack(spacing: NBRowMetrics.contentSpacing) {
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
				Text(desc)
					.frame(maxWidth: .infinity, alignment: .leading)
					.nbRowSubtitle()
					.foregroundStyle(.secondary)
					.padding(.top, 2)
			}
		}
	}

	/// Keep the navigation target separate from the download control, including
	/// in large-description mode.
	@ViewBuilder
	private func _selectableContent<Content: View>(@ViewBuilder content: () -> Content) -> some View {
		switch selectionOwner {
		case .swiftUIButton:
			if let onSelect {
				Button(action: onSelect) {
					content()
						.accessibilityElement(children: .combine)
						.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				.accessibilityHint(String.localized("Opens app details"))
			} else {
				content()
			}
		case .tableView:
			// Touch navigation is owned by UITableViewDelegate; this default action
			// keeps the hosted app details accessible without a competing Button.
			content()
				.contentShape(Rectangle())
				.accessibilityElement(children: .combine)
				.accessibilityHint(String.localized("Opens app details"))
				.accessibilityAction(.default) { onSelect?() }
		}
	}

	private var _appDetails: some View {
        FRIconCellView(title: app.currentName, iconUrl: app.iconURL,
            badgeURL: showSourceBadge ? source.currentIconURL : nil) {
            _subtitleView()
        }
	}

	@ViewBuilder
	private func _subtitleView() -> some View {
		let version = app.currentVersion.flatMap { $0.isEmpty ? nil : $0 }

		VStack(alignment: .leading, spacing: NBRowMetrics.lineSpacing) {
			if let version {
				Text(version)
					.nbRowSubtitle()
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
