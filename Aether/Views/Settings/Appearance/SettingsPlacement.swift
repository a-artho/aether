import Foundation

enum SettingsPlacement: String, CaseIterable, Identifiable {
	case header, tabBar
	var id: Self { self }
	var label: String {
		switch self {
		case .header: .localized("Header")
		case .tabBar: .localized("Tab Bar")
		}
	}

	static func usesTab(placement: Self) -> Bool {
		placement == .tabBar
	}

	static var usesTab: Bool {
		usesTab(placement: Self(rawValue: UserDefaults.standard.string(forKey: "Aether.settingsPlacement") ?? "") ?? .header)
	}
}
