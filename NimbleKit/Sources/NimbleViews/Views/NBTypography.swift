import SwiftUI

/// Shared app typography. Secondary text scales with the native subheadline curve.
public enum NBTypography {
	public static let secondaryPointSize: CGFloat = 14
	public static let sectionHeading: Font = .headline
}

public extension View {
	func nbFont(_ style: Font.TextStyle, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
		modifier(NBFontModifier(style: style, weight: weight, design: design))
	}
}

private struct NBFontModifier: ViewModifier {
	@ScaledMetric(relativeTo: .subheadline) private var secondarySize = NBTypography.secondaryPointSize
	let style: Font.TextStyle
	let weight: Font.Weight
	let design: Font.Design

	func body(content: Content) -> some View {
		content.font(style == .subheadline
			? .system(size: secondarySize, weight: weight, design: design)
			: .system(style, design: design).weight(weight))
	}
}
