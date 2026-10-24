import Foundation

/// Main row artwork only; accessory buttons, badges and detail artwork keep their sizes.
enum RowIconSize: Int, CaseIterable, Identifiable {
	case standard = 50, medium = 54, large = 58
	var id: Self { self }
	var points: CGFloat { CGFloat(rawValue) }
	var symbolPoints: CGFloat {
		switch self {
		case .standard: 30
		case .medium: 32
		case .large: 35
		}
	}
	var title: String {
		switch self {
		case .standard: .localized("Default")
		case .medium: .localized("Medium")
		case .large: .localized("Large")
		}
	}
}
