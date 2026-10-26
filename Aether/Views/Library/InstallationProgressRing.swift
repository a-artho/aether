import SwiftUI

struct InstallationProgressRing: View {
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	let progress: Double?
	let systemImage: String

	var body: some View {
		ZStack {
			if let progress {
				Circle()
					.trim(from: 0, to: progress)
					.stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.3, lineCap: .round))
					.frame(width: 35, height: 35)
					.rotationEffect(.degrees(-90))
					.animation(reduceMotion ? nil : .smooth, value: progress)
			}
			Image(systemName: systemImage)
				.contentTransition(.symbolEffect(.replace))
				.foregroundStyle(Color.accentColor)
				.font(.footnote.bold())
		}
		.frame(width: 35, height: 35)
	}
}

