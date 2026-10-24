import SwiftUI

public enum NBRowMetrics {
	public static let lineSpacing: CGFloat = 3
	public static let contentSpacing: CGFloat = 18
	public static let textVerticalPadding: CGFloat = 2
}

public enum NBRowInset: Int, CaseIterable {
	case system, twenty, twentyTwo, twentyFour
	public var horizontal: CGFloat? {
		switch self {
		case .system: nil
		case .twenty: 20
		case .twentyTwo: 22
		case .twentyFour: 24
		}
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

private struct NBOptionalRowInsets: ViewModifier {
	@AppStorage("Aether.rowInset") private var inset: NBRowInset = .system
	func body(content: Content) -> some View {
		if let horizontal = inset.horizontal {
			content.listRowInsets(.horizontal, horizontal)
		} else {
			content
		}
	}
}

public extension View {
	func nbOptionalRowInsets() -> some View { modifier(NBOptionalRowInsets()) }
	func nbRowTitle() -> some View { modifier(NBRowText(title: true)) }
	func nbRowSubtitle() -> some View { modifier(NBRowText(title: false)) }
}
