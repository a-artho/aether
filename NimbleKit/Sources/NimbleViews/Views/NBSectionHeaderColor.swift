import SwiftUI

public extension View {
	/// Changes only the heading's color, preserving its typography and layout.
	func nbSectionHeaderColor() -> some View {
		modifier(NBSectionHeaderColor())
	}
}

private struct NBSectionHeaderColor: ViewModifier {
	@AppStorage("Aether.mutedSectionHeaders") private var muted = false

	func body(content: Content) -> some View {
		content.foregroundStyle(muted ? Color.secondary : Color.primary)
	}
}
