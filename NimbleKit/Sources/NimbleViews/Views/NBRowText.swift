import SwiftUI
import UIKit

public enum NBRowTextStyle: String, CaseIterable, Identifiable {
	case standard, compact, balanced
	public var id: Self { self }
	public var title: String {
		switch self {
		case .standard: String(localized: "Default")
		case .compact: String(localized: "Compact")
		case .balanced: String(localized: "Balanced")
		}
	}
	public var lineSpacing: CGFloat { self == .balanced ? 3 : 2 }
}

/// Compact preserves the original line slots; Balanced uses explicit stack spacing.
private struct NBRowText: ViewModifier {
	@AppStorage("Aether.rowTextStyle") private var style: NBRowTextStyle = .standard
	@ScaledMetric private var compactSize: CGFloat
	@ScaledMetric private var balancedSize: CGFloat
	@ScaledMetric private var originalHeight: CGFloat
	@ScaledMetric private var compactHeight: CGFloat
	let title: Bool

	init(title: Bool) {
		self.title = title
		let style: Font.TextStyle = title ? .headline : .subheadline
		let weight: UIFont.Weight = title ? .semibold : .regular
		let size: CGFloat = title ? 16 : 13
		_compactSize = ScaledMetric(wrappedValue: size, relativeTo: style)
		_balancedSize = ScaledMetric(wrappedValue: title ? 16 : 14, relativeTo: style)
		_originalHeight = ScaledMetric(wrappedValue: UIFont.systemFont(ofSize: title ? 17 : 15, weight: weight).lineHeight, relativeTo: style)
		_compactHeight = ScaledMetric(wrappedValue: UIFont.systemFont(ofSize: size, weight: weight).lineHeight, relativeTo: style)
	}

	func body(content: Content) -> some View {
		let extra = style == .compact ? max(0, originalHeight - compactHeight) : 0
		let size = style == .balanced ? balancedSize : compactSize
		content
			.font(style == .standard ? (title ? .headline : .subheadline) : .system(size: size, weight: title ? .semibold : .regular))
			.lineSpacing(extra)
			.padding(.vertical, extra / 2)
	}
}

public extension View {
	func nbRowTitle() -> some View { modifier(NBRowText(title: true)) }
	func nbRowSubtitle() -> some View { modifier(NBRowText(title: false)) }
}
