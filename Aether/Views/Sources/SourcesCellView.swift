//
//  SourcesCellView.swift
//  Aether
//
//  Created by samara on 1.05.2025.
//

import SwiftUI
import NimbleViews
import NukeUI

// MARK: - View
struct SourcesCellView: View {
	@AppStorage("Aether.overviewIconStyle") private var overviewIconStyle: OverviewIconStyle = .glass
	@Environment(\.horizontalSizeClass) private var horizontalSizeClass
	
	var source: AltSource
	var isRefreshing = false
	
	// MARK: Body
	var body: some View {
		let isRegular = horizontalSizeClass != .compact
		
		HStack(spacing: 12) {
		FRIconCellView(
			title: (source.name ?? .localized("Unknown")).repoDisplayName,
			iconUrl: source.iconURL,
				overviewStyle: overviewIconStyle
		) {
			if let url = source.sourceURL?.absoluteString {
				Text(url)
			}
		}
			if isRefreshing { ProgressView().controlSize(.small) }
		}
		.padding(isRegular ? 12 : 0)
		.background(
			isRegular
				? RoundedRectangle(cornerRadius: 18, style: .continuous)
				.fill(Color(.quaternarySystemFill))
				: nil
		)
		.swipeActions {
			_actions(for: source)
			_contextActions(for: source)
		}
		.contextMenu {
			_contextActions(for: source)
			Divider()
			_actions(for: source)
		}
	}
}

// MARK: - Extension: View
extension SourcesCellView {
	@ViewBuilder
	private func _actions(for source: AltSource) -> some View {
		Button(.localized("Delete"), systemImage: "trash", role: .destructive) {
			Storage.shared.deleteSource(for: source)
		}
	}
	
	@ViewBuilder
	private func _contextActions(for source: AltSource) -> some View {
		Button(.localized("Copy"), systemImage: "doc.on.clipboard") {
			UIPasteboard.general.string = source.sourceURL?.absoluteString
		}
	}
}

/// Presentation only: catalog identity and persisted names remain intact.
extension String {
	var repoDisplayName: String {
		let cleaned = replacingOccurrences(of: #"(?i)\b(?:repos?|repositories|repository|sources?)\b"#,
			with: "", options: .regularExpression)
			.replacingOccurrences(of: #"\(\s*[/|:–—-]*\s*\)|\[\s*[/|:–—-]*\s*\]|\{\s*[/|:–—-]*\s*\}"#,
				with: "", options: .regularExpression)
			.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
			.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—|:•/\\")))
		return cleaned.isEmpty ? self : cleaned
	}
}
