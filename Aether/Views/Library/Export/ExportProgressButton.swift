import SwiftUI

struct ExportProgressButton: View {
	@ObservedObject var export: AppExport

	var body: some View {
		Button(action: _performAction) {
			ZStack {
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
			.frame(width: ActionProgressRingMetrics.diameter, height: ActionProgressRingMetrics.diameter)
			.frame(width: 44, height: 44, alignment: .trailing)
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
