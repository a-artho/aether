//
//  SourcesCellView.swift
//  Aether
//
//  Created by samara on 1.05.2025.
//

import SwiftUI
import NimbleViews
import NukeUI

private func compactRepoAppsCount(_ count: Int) -> String {
	guard count >= 1_000 else { return String(count) }
	let units = ["k", "m", "b", "t"]
	var value = Double(count)
	var unit = -1
	while value >= 1_000 && unit < units.count - 1 {
		value /= 1_000
		unit += 1
	}
	var rounded = value < 10 ? (value * 10).rounded() / 10 : value.rounded()
	if rounded >= 1_000 && unit < units.count - 1 {
		rounded /= 1_000
		unit += 1
	}
	let number = rounded < 10 && rounded != rounded.rounded()
		? String(format: "%.1f", locale: Locale.current, rounded)
		: String(format: "%.0f", locale: Locale.current, rounded)
	return number + units[unit]
}

// MARK: - View
struct SourcesCellView: View {
	@AppStorage("Aether.overviewIconStyle") private var overviewIconStyle: OverviewIconStyle = .glass
	@AppStorage("Aether.showRepoAppsCount") private var showAppsCount = false
	@Environment(\.horizontalSizeClass) private var horizontalSizeClass
	
	var source: AltSource
	var isRefreshing = false
	var appCount: Int? = nil
	private var displayURL: String? {
		guard let url = source.sourceURL?.absoluteString else { return nil }
		var display = url.hasPrefix("https://") ? String(url.dropFirst(8)) : url
		if display.hasSuffix("/") { display.removeLast() }
		return display
	}
	
	// MARK: Body
	var body: some View {
		let isRegular = horizontalSizeClass != .compact
		
		HStack(spacing: 12) {
		FRIconCellView(
			title: (source.name ?? .localized("Unknown")).repoDisplayName,
			iconUrl: source.iconURL,
				overviewStyle: overviewIconStyle
		) {
			if let url = displayURL {
				Text(url)
			}
		}
			if isRefreshing { ProgressView().controlSize(.small) }
			if showAppsCount, let appCount {
				Text(compactRepoAppsCount(appCount))
					.font(.footnote)
					.foregroundStyle(.secondary)
					.monospacedDigit()
					.fixedSize(horizontal: true, vertical: false)
					.frame(minWidth: 20, minHeight: 20)
					.accessibilityLabel(String.localized("%@ apps", arguments: appCount.formatted()))
			}
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
