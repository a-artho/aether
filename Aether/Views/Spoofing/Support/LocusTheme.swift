import SwiftUI

enum LocusTheme {
    static let accent = Color.accentColor
    static let accentSecondary = Color.accentColor
    static let danger = Color(uiColor: .systemRed)
    static let panelStroke = Color.white.opacity(0.12)
    static let statusGood = Color(red: 0.30, green: 0.86, blue: 0.55)
    static let statusWarn = Color(red: 0.98, green: 0.78, blue: 0.28)
    static let statusBad = Color(red: 0.92, green: 0.32, blue: 0.36)
}

enum LocusGlassStyle {
    case regular
    case clear
    case interactive
}

struct LocusGlassModifier<S: Shape>: ViewModifier {
    var style: LocusGlassStyle
    var shape: S
	var tint: Color?

	func body(content: Content) -> some View {
		content
			.glassEffect(glass, in: shape)
			// Glass draws outside the layout bounds; expand hit-testing to match.
			.contentShape(shape)
	}

	private var glass: Glass {
        var g: Glass = style == .clear ? .clear : .regular
        if style == .interactive { g = g.interactive() }
        if let tint { g = g.tint(tint) }
        return g
    }
}

extension View {
    func locusGlass<S: Shape>(
        _ style: LocusGlassStyle = .regular,
        tint: Color? = nil,
        in shape: S
    ) -> some View {
        modifier(LocusGlassModifier(style: style, shape: shape, tint: tint))
    }

    func locusGlass(_ style: LocusGlassStyle = .regular, tint: Color? = nil) -> some View {
        locusGlass(style, tint: tint, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
