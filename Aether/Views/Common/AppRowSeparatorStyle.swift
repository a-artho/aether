import SwiftUI
import UIKit

enum AppRowSeparatorStyle: Int, CaseIterable, Identifiable {
	case standard = 0
	case half
	case off

	var id: Self { self }

	var title: String {
		switch self {
		case .standard: .localized("Default")
		case .half: .localized("Half")
		case .off: .localized("Off")
		}
	}

	var listTint: Color? { self == .half ? Color(uiColor: .separator).opacity(0.5) : nil }

	@MainActor func apply(to tableView: UITableView) {
		tableView.separatorStyle = self == .off ? .none : .singleLine
		if self == .half {
			tableView.separatorColor = UIColor { traits in
				let separator = UIColor.separator.resolvedColor(with: traits)
				return separator.withAlphaComponent(separator.cgColor.alpha * 0.5)
			}
		} else {
			tableView.separatorColor = .separator
		}
	}
}

private struct AppRowSeparatorModifier: ViewModifier {
	let style: AppRowSeparatorStyle

	@ViewBuilder
	func body(content: Content) -> some View {
		switch style {
		case .standard:
			content
		case .half:
			content.listRowSeparatorTint(style.listTint)
		case .off:
			content.listRowSeparator(.hidden)
		}
	}
}

extension View {
	func appRowSeparatorStyle(_ style: AppRowSeparatorStyle) -> some View {
		modifier(AppRowSeparatorModifier(style: style))
	}
}
