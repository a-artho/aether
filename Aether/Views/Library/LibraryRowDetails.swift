import SwiftUI
import NimbleViews

/// Shared metadata hierarchy for Library apps and in-flight transfers.
struct LibraryRowDetails: View {
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
				thirdLineContent
					.font(.footnote)
					.foregroundStyle(.secondary)
					.contentTransition(reduceMotion ? .identity : (crossfadesStatus ? .opacity : (showsNumericProgress ? .identity : .interpolate)))
					.animation(textAnimation, value: statusIdentity)
					.accessibilityHidden(thirdLineText.isEmpty)
			}
		}
		.padding(.vertical, NBRowMetrics.textVerticalPadding)
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	@ViewBuilder private var thirdLineContent: some View {
		let text = thirdLineText.isEmpty ? " " : thirdLineText
		if thirdLineStatus != nil && !dynamicTypeSize.isAccessibilitySize {
			// Prefer one natural-size line; if it cannot fit, preserve the full
			// message instead of truncating it or shrinking it to unreadable text.
			ViewThatFits(in: .horizontal) {
				Text(text).lineLimit(1).fixedSize(horizontal: true, vertical: true)
				Text(text).fixedSize(horizontal: false, vertical: true)
			}
		} else {
			Text(text)
				.lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
				.fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
		}
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
