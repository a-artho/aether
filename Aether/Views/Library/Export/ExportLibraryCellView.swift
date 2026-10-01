//
//  ExportLibraryCellView.swift
//  Aether
//

import NimbleExtensions
import SwiftUI

struct ExportLibraryCellView: View {
	@Environment(\.horizontalSizeClass) private var horizontalSizeClass
	@ObservedObject var export: AppExport

	var body: some View {
		HStack(spacing: 18) {
			FRAppIconView(app: export.app, size: 50)

			VStack(alignment: .leading, spacing: 3) {
				Text(export.app.name ?? .localized("Unknown"))
					.font(.headline)
					.lineLimit(1)
				Text(_subtitle)
					.font(.subheadline)
					.foregroundStyle(_isFailed ? Color.red : Color.secondary)
					.lineLimit(2)
			}
			.frame(maxWidth: .infinity, alignment: .leading)

			ExportProgressButton(export: export)
		}
		.padding(horizontalSizeClass == .compact ? 0 : 12)
		.background {
			if horizontalSizeClass != .compact {
				RoundedRectangle(cornerRadius: 18, style: .continuous)
					.fill(Color(.quaternarySystemFill))
			}
		}
		.swipeActions(edge: .trailing, allowsFullSwipe: true) {
			Button(.localized("Delete"), systemImage: "trash", role: .destructive) {
				ExportManager.shared.cancel(export)
			}
		}
	}

	private var _isFailed: Bool {
		if case .failed = export.state { return true }
		return false
	}

	private var _subtitle: String {
		switch export.state {
		case .exporting:
			return "\(String.localized("Processing")) \(Int(export.progress * 100))%"
		case .failed(let message):
			return message.isEmpty ? .localized("Error") : message
		}
	}
}

private struct ExportProgressButton: View {
	@ObservedObject var export: AppExport

	var body: some View {
		Button(action: _performAction) {
			ZStack {
				Circle()
					.stroke(_tint.opacity(0.2), lineWidth: 2.3)

				if case .exporting = export.state {
					Circle()
						.trim(from: 0, to: export.progress)
						.stroke(_tint, style: StrokeStyle(lineWidth: 2.3, lineCap: .round))
						.rotationEffect(.degrees(-90))
						.animation(.smooth, value: export.progress)
				}

				Image(systemName: _systemImage)
					.foregroundStyle(_tint)
					.font(.footnote.bold())
			}
			.frame(width: 31, height: 31)
			.frame(width: 44, height: 44)
			.contentShape(Rectangle())
		}
		.buttonStyle(.borderless)
		.accessibilityLabel(_accessibilityLabel)
	}

	private var _tint: Color {
		if case .failed = export.state { return .red }
		return .accentColor
	}

	private var _systemImage: String {
		switch export.state {
		case .exporting: return "xmark"
		case .failed: return "arrow.clockwise"
		}
	}

	private var _accessibilityLabel: String {
		switch export.state {
		case .exporting: return "Cancel Export"
		case .failed: return "Retry Export"
		}
	}

	private func _performAction() {
		switch export.state {
		case .exporting:
			ExportManager.shared.cancel(export)
		case .failed:
			ExportManager.shared.retry(export)
		}
	}
}
