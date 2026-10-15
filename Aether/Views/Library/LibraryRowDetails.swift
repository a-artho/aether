import SwiftUI

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
	var statusColor: Color = .secondary

	var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			Text(name)
				.font(.headline)
				.foregroundStyle(.primary)
				.lineLimit(1)

			Text(_secondLine)
				.font(.subheadline)
				.contentTransition(.interpolate)
				.animation(animatesStatus && !reduceMotion ? .smooth(duration: 0.2) : nil, value: secondaryStatus)
				.foregroundStyle(isFailed ? Color.red : Color.secondary)
				.lineLimit(isFailed ? 2 : 1)

			if let thirdLineStatus {
				Text(thirdLineStatus)
					.monospacedDigit()
					.font(.footnote)
					.foregroundStyle(statusColor)
					.lineLimit(nil)
					.fixedSize(horizontal: false, vertical: true)
					.contentTransition(showsNumericProgress ? .identity : .interpolate)
					.animation(animatesStatus && !reduceMotion ? .smooth(duration: 0.2) : nil, value: thirdLineAnimationKey ?? thirdLineStatus)
			} else if let identifier, !identifier.isEmpty {
				Text(identifier)
					.font(.footnote)
					.foregroundStyle(.secondary)
					.lineLimit(1)
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
