import SwiftUI

enum OverviewIconStyle: String, CaseIterable, Identifiable {
	case standalone, glass
	var id: Self { self }
	var title: String {
		switch self {
		case .standalone: .localized("Standalone")
		case .glass: .localized("Glass")
		}
	}
}

enum AllReposIcon: String, CaseIterable, Identifiable {
	case appStore, globe, books
	var id: Self { self }
	var title: String {
		switch self {
		case .appStore: .localized("App Store")
		case .globe: .localized("Globe")
		case .books: .localized("Books")
		}
	}
	var systemImage: String {
		switch self {
		case .appStore: "appstore"
		case .globe: "globe.desk"
		case .books: "books.vertical"
		}
	}
}

/// Overview symbols share the app artwork footprint without changing row layout.
struct OverviewRowIcon: View {
	enum Kind { case apps, repos }
	let kind: Kind
	@AppStorage("Aether.overviewIconStyle") private var style: OverviewIconStyle = .standalone
	@AppStorage("Aether.allReposIcon") private var reposIcon: AllReposIcon = .appStore
	@AppStorage("Aether.rowIconSize") private var rowIconSize: RowIconSize = .standard
	private var size: CGFloat { rowIconSize.points }
	var body: some View {
		symbol
			.foregroundStyle(.secondary)
			.frame(width: size, height: size)
			.modifier(OverviewIconSurface(style: style, size: size))
			.accessibilityHidden(true)
	}

	@ViewBuilder private var symbol: some View {
		switch kind {
		case .apps:
			Image(systemName: "square.stack.3d.up.fill")
				.font(.system(size: rowIconSize.symbolPoints, weight: .regular))
				.symbolRenderingMode(.hierarchical)
		case .repos:
			if reposIcon == .appStore {
				Image("AppStoreLogo")
					.renderingMode(.template)
					.resizable()
					.scaledToFit()
					.frame(width: rowIconSize.symbolPoints, height: rowIconSize.symbolPoints)
			} else {
				Image(systemName: reposIcon.systemImage)
					.font(.system(size: rowIconSize.symbolPoints, weight: .regular))
					.symbolRenderingMode(.hierarchical)
			}
		}
	}
}

/// The same surface is used for overview symbols and, optionally, repo artwork.
struct OverviewIconSurface: ViewModifier {
	let style: OverviewIconStyle
	let size: CGFloat
	var isCircle = false
	private var shape: RoundedRectangle {
		RoundedRectangle(cornerRadius: isCircle ? size / 2 : size * 0.2677, style: .continuous)
	}

	func body(content: Content) -> some View {
		content
			.background {
				switch style {
				case .standalone: EmptyView()
				case .glass: Color.clear.glassEffect(.regular, in: shape)
				}
			}
	}
}
