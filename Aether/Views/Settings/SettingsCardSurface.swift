import SwiftUI
import NimbleViews

/// Shared surface for Settings cards that are not hosted in a grouped form.
struct SettingsCardSurface: ViewModifier {
	@AppStorage("Aether.deviceControlsStyle") private var style: DeviceControlsStyle = .standard
	let color: Color
	let cornerRadius: CGFloat

	func body(content: Content) -> some View {
		content.background {
			if style == .liquidGlass {
				Color.clear.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
			} else {
				RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(color)
			}
		}
	}
}
