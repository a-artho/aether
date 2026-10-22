import SwiftUI
import NimbleViews

/// Shared metadata hierarchy for Library apps and in-flight transfers.
struct LibraryRowDetails: View {
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	let name: String
	let version: String?
	let identifier: String?
	var secondaryStatus: String? = nil
	var isFailed = false
	var animatesStatus = false
	var thirdLineStatus: String? = nil
	var thirdLineAnimationKey: String? = nil
	var showsNumericProgress = false

	var body: some View {
		VStack(alignment: .leading, spacing: NBRowMetrics.lineSpacing) {
			Text(name)
				.nbRowTitle()
				.foregroundStyle(.primary)
				.lineLimit(1)

			Text(_secondLine)
				.nbRowSubtitle()
				.contentTransition(.interpolate)
				.animation(animatesStatus && !reduceMotion ? .smooth(duration: 0.2) : nil, value: secondaryStatus)
				.foregroundStyle(isFailed ? Color.red : Color.secondary)
				.lineLimit(isFailed ? 2 : 1)

			if let text = thirdLineStatus ?? identifier, !text.isEmpty {
				Text(text)
					.font(.footnote)
					.foregroundStyle(.secondary)
					.lineLimit(1)
					.minimumScaleFactor(thirdLineStatus != nil ? 0.5 : 1)
					.allowsTightening(thirdLineStatus != nil)
					.contentTransition(showsNumericProgress ? .identity : .interpolate)
					.animation(animatesStatus && thirdLineStatus != nil && !reduceMotion ? .smooth(duration: 0.2) : nil,
						value: thirdLineAnimationKey ?? thirdLineStatus)
			}
		}
		.padding(.vertical, 2)
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	private var _secondLine: String {
		[version, secondaryStatus]
			.compactMap { $0 }
			.filter { !$0.isEmpty }
			.joined(separator: " | ")
	}
}
