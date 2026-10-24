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
	var crossfadesStatus = false

	var body: some View {
		VStack(alignment: .leading, spacing: NBRowMetrics.lineSpacing) {
			Text(name)
				.contentTransition(crossfadesStatus && !reduceMotion ? .opacity : .identity)
				.animation(textAnimation, value: name)
				.nbRowTitle()
				.foregroundStyle(.primary)
				.lineLimit(1)

			Text(crossfadesStatus && _secondLine.isEmpty ? " " : _secondLine)
				.nbRowSubtitle()
				.contentTransition(crossfadesStatus ? .opacity : .interpolate)
				.animation(textAnimation, value: _secondLine)
				.foregroundStyle(isFailed ? Color.red : Color.secondary)
				.lineLimit(isFailed ? 2 : 1)

			if crossfadesStatus || !thirdLineText.isEmpty {
				Text(thirdLineText.isEmpty ? " " : thirdLineText)
					.font(.footnote)
					.foregroundStyle(.secondary)
					.lineLimit(thirdLineStatus != nil ? nil : 1)
					.fixedSize(horizontal: false, vertical: thirdLineStatus != nil)
					.allowsTightening(thirdLineStatus != nil)
					.contentTransition(reduceMotion ? .identity : (crossfadesStatus ? .opacity : (showsNumericProgress ? .identity : .interpolate)))
					.animation(textAnimation, value: statusIdentity)
					.accessibilityHidden(thirdLineText.isEmpty)
			}
		}
		.padding(.vertical, NBRowMetrics.textVerticalPadding)
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	private var textAnimation: Animation? {
		animatesStatus && !reduceMotion ? .easeInOut(duration: 0.2) : nil
	}

	private var thirdLineText: String { thirdLineStatus ?? identifier ?? "" }

	private var statusIdentity: String {
		thirdLineAnimationKey ?? thirdLineStatus ?? identifier ?? ""
	}

	private var _secondLine: String {
		[version, secondaryStatus]
			.compactMap { $0 }
			.filter { !$0.isEmpty }
			.joined(separator: " | ")
	}
}
