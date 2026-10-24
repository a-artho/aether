import SwiftUI

/// Native replacement for a status phase. Live values keep the same identity,
/// so byte counts update in place instead of replaying the phase transition.
struct StatusTransitionText<Content: View>: View {
	let text: String
	let phase: String
	@ViewBuilder var content: (String) -> Content
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	init(_ text: String, phase: String, @ViewBuilder content: @escaping (String) -> Content) {
		self.text = text
		self.phase = phase
		self.content = content
	}

	var body: some View {
		ZStack(alignment: .topLeading) {
			// Measure the current label while SwiftUI retains the outgoing one.
			content(text).hidden().accessibilityHidden(true)
			content(text)
				.contentTransition(.identity)
				.id(phase)
				.transition(.blurReplace)
		}
		.animation(reduceMotion ? nil : .smooth(duration: 0.3), value: phase)
		.transaction { transaction in
			if reduceMotion {
				transaction.animation = nil
				transaction.disablesAnimations = true
			}
		}
	}
}
