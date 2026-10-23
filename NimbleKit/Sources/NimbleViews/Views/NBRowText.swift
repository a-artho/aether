import SwiftUI

public enum NBRowMetrics {
	public static let lineSpacing: CGFloat = 3
	public static let contentSpacing: CGFloat = 18
	public static let textVerticalPadding: CGFloat = 2
	public static let horizontalInset: CGFloat = 20
	public static let verticalInset: CGFloat = 8
	public static var listInsets: EdgeInsets {
		EdgeInsets(top: verticalInset, leading: horizontalInset, bottom: verticalInset, trailing: horizontalInset)
	}
}

/// Balanced typography with Dynamic Type scaling throughout the app.
private struct NBRowText: ViewModifier {
	@ScaledMetric private var size: CGFloat
	let title: Bool

	init(title: Bool) {
		self.title = title
		_size = ScaledMetric(wrappedValue: title ? 16 : 14,
			relativeTo: title ? .headline : .subheadline)
	}

	func body(content: Content) -> some View {
		content.font(.system(size: size, weight: title ? .semibold : .regular))
	}
}

public extension View {
	func nbRowTitle() -> some View { modifier(NBRowText(title: true)) }
	func nbRowSubtitle() -> some View { modifier(NBRowText(title: false)) }
}
