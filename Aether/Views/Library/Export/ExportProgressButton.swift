import SwiftUI

struct ExportProgressButton: View {
	@ObservedObject var export: AppExport
	var showsTrack = true

	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	var body: some View {
		Button(action: _performAction) {
			ZStack {
				Circle()
					.stroke(_tint.opacity(0.2), lineWidth: 2.3)
					.opacity(showsTrack ? 1 : 0)

				if case .exporting = export.state {
					Circle()
						.trim(from: 0, to: export.progress)
						.stroke(_tint, style: StrokeStyle(lineWidth: 2.3, lineCap: .round))
						.rotationEffect(.degrees(-90))
						.animation(reduceMotion ? nil : .smooth, value: export.progress)
				}

				Image(systemName: _systemImage)
					.foregroundStyle(_tint)
					.font(.footnote.bold())
					.contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
					.animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: _systemImage)
			}
			.animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: _systemImage)
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
