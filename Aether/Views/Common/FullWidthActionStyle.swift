import SwiftUI

extension View {
	/// Shared native appearance for the large signing, pairing and news actions.
	func fullWidthActionStyle() -> some View {
		self
			.buttonStyle(.glassProminent)
			.tint(.accentColor)
			.controlSize(.large)
	}
}
