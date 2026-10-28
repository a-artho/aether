import SwiftUI
import NimbleViews

/// Shared surface for Settings cards that are not hosted in a grouped form.
struct SettingsCardSurface: ViewModifier {
	@AppStorage("Aether.deviceControlsStyle") private var style: DeviceControlsStyle = .standard
	let color: Color
	let cornerRadius: CGFloat

	@ViewBuilder
	func body(content: Content) -> some View {
		if style == .liquidGlass {
			content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
		} else {
			content.background {
				RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(color)
			}
		}
	}
}
