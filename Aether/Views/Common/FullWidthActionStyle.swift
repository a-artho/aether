import SwiftUI

extension View {
	/// Shared native appearance for large primary actions.
	func fullWidthActionStyle() -> some View {
		self
			.buttonStyle(.glassProminent)
			.tint(.accentColor)
			.controlSize(.large)
	}
}
