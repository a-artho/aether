import SwiftUI

/// Native replacement for a status phase. Live values keep the same identity,
/// so byte counts update in place instead of replaying the phase transition.
struct StatusTransitionText<Content: View>: View {
	let text: String
	let phase: String
	let duration: TimeInterval
	@ViewBuilder var content: (String) -> Content
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	init(_ text: String, phase: String, duration: TimeInterval = 0.3, @ViewBuilder content: @escaping (String) -> Content) {
		self.text = text
		self.phase = phase
		self.duration = duration
		self.content = content
	}

	var body: some View {
		ZStack(alignment: .topLeading) {
			// Keep the row's measured height stable while SwiftUI replaces the
			// visible text in place with a native blur transition.
			content(text).hidden().accessibilityHidden(true)
			content(text)
				.contentTransition(reduceMotion ? .identity : .blurReplace)
		}
		// Apply animation to the replacement container so inherited List
		// transactions cannot turn the text swap into an unanimated redraw.
		.animation(reduceMotion ? nil : .smooth(duration: duration), value: phase)
	}
}
