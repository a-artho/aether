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

	var listVisibility: Visibility? { self == .off ? .hidden : nil }
	var listTint: Color? { self == .half ? Color(uiColor: .separator).opacity(0.5) : nil }

	func apply(to tableView: UITableView) {
		tableView.separatorStyle = self == .off ? .none : .singleLine
		tableView.separatorColor = self == .half
			? UIColor.separator.withAlphaComponent(0.5)
			: UIColor.separator
	}
}
