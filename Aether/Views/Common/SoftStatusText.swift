import SwiftUI

/// Swap a label at low opacity, without layering two readable sentences.
/// Changes within the same phase (for example byte counts) update in place.
struct SoftStatusText<Content: View>: View {
	let text: String
	let phase: String
	@ViewBuilder var content: (String) -> Content
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@State private var displayed: String
	@State private var latest: String
	@State private var displayedPhase: String
	@State private var opacity: Double = 1

	init(_ text: String, phase: String, @ViewBuilder content: @escaping (String) -> Content) {
		self.text = text
		self.phase = phase
		self.content = content
		_displayed = State(initialValue: text)
		_latest = State(initialValue: text)
		_displayedPhase = State(initialValue: phase)
	}

	var body: some View {
		ZStack(alignment: .topLeading) {
			content(text).hidden().accessibilityHidden(true)
			content(displayed)
				.transaction { $0.animation = nil }
				.opacity(opacity)
		}
		.onChange(of: text) { _, value in
			latest = value
			if displayedPhase == phase { displayed = value }
		}
		.task(id: [phase, String(reduceMotion)]) { await transitionText() }
	}

	private func transitionText() async {
			latest = text
			guard displayedPhase != phase, !reduceMotion else {
				displayed = text
				displayedPhase = phase
				withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) { opacity = 1 }
				return
			}
			withAnimation(.easeIn(duration: 0.1)) { opacity = 0.1 }
			do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
			guard !Task.isCancelled else { return }
			displayed = latest
			displayedPhase = phase
			withAnimation(.easeOut(duration: 0.14)) { opacity = 1 }

	}
}
