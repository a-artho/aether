import Foundation

/// Nil preserves each screen's native horizontal insets.
enum RowHorizontalInset: Int, CaseIterable, Identifiable {
	case standard = 0, medium = 20, large = 24
	var id: Self { self }
	var points: CGFloat? { self == .standard ? nil : CGFloat(rawValue) }
	var title: String {
		switch self {
		case .standard: .localized("Default")
		case .medium: .localized("Medium")
		case .large: .localized("Large")
		}
	}
}
