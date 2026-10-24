import SwiftUI

/// Shared appearance for the large signing, pairing and news actions.
enum FullWidthActionStyle: String, CaseIterable, Identifiable {
	case current
	case glass

	var id: Self { self }
	var title: String {
		switch self {
		case .current: .localized("Current")
		case .glass: .localized("Glass")
		}
	}
}

private struct FullWidthActionAppearance: ViewModifier {
	@AppStorage("Aether.fullWidthActionStyle") private var style: FullWidthActionStyle = .current

	func body(content: Content) -> some View {
		Group {
			switch style {
			case .current:
				content.buttonStyle(.glassProminent).tint(.accentColor)
			case .glass:
				content.buttonStyle(.glass).foregroundStyle(Color.accentColor)
			}
		}
		.controlSize(.large)
	}
}

extension View {
	func fullWidthActionStyle() -> some View {
		modifier(FullWidthActionAppearance())
	}
}
