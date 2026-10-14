import SwiftUI

struct InstallationProgressRing: View {
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	let progress: Double?
	let systemImage: String

	var body: some View {
		ZStack {
			Circle()
				.stroke(Color.accentColor.opacity(0.2), lineWidth: 2.3)
			if let progress {
				Circle()
					.trim(from: 0, to: progress)
					.stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.3, lineCap: .round))
					.rotationEffect(.degrees(-90))
					.animation(reduceMotion ? nil : .smooth, value: progress)
			}
			Image(systemName: systemImage)
				.contentTransition(.symbolEffect(.replace))
				.foregroundStyle(Color.accentColor)
				.font(.footnote.bold())
		}
		.frame(width: 31, height: 31)
		.frame(width: 44, height: 44)
	}
}

