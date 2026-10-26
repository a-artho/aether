import SwiftUI
import UIKit

/// A static, theme-aware page background. The preference defaults to the
/// existing system surface, so enabling the effect is always opt-in.
struct AetherAmbientBackground: View {
	enum Base {
		case standard
		case grouped

		var color: UIColor {
			switch self {
			case .standard: .systemBackground
			case .grouped: .systemGroupedBackground
			}
		}
	}

	@AppStorage("Aether.ambientBackgroundEnabled") private var isEnabled = false
	@AppStorage("Aether.userTintColor") private var themeHex = "#848ef9"
	@Environment(\.colorScheme) private var colorScheme

	var base: Base = .standard

	private var accent: Color { Color(hex: themeHex) }

	var body: some View {
		ZStack {
			Color(uiColor: base.color)

			if isEnabled && colorScheme == .dark {
				GeometryReader { geometry in
					ZStack {
						RadialGradient(
							stops: [
								.init(color: accent.opacity(0.15), location: 0),
								.init(color: accent.opacity(0.045), location: 0.5),
								.init(color: .clear, location: 1)
							],
							center: UnitPoint(x: 0.5, y: -0.04),
							startRadius: 0,
							endRadius: 450
						)

						RadialGradient(
							stops: [
								.init(color: accent.opacity(0.05), location: 0),
								.init(color: accent.opacity(0.018), location: 0.52),
								.init(color: .clear, location: 1)
							],
							center: UnitPoint(x: 0.5, y: 1.08),
							startRadius: 0,
							endRadius: 330
						)
					}
					.frame(width: geometry.size.width, height: geometry.size.height)
				}
			}
		}
		.ignoresSafeArea()
		// This is a stationary page surface. Never interpolate its geometry when
		// a parent animates list insertions or the initial layout settles.
		.transaction {
			$0.animation = nil
			$0.disablesAnimations = true
		}
		.allowsHitTesting(false)
		.accessibilityHidden(true)
	}
}

extension View {
	/// Reveals the shared ambient surface behind a native List or Form.
	func aetherAmbientScrollBackground(
		base: AetherAmbientBackground.Base = .standard
	) -> some View {
		scrollContentBackground(.hidden)
			.background { AetherAmbientBackground(base: base) }
	}

	/// Adds the shared ambient surface behind a regular scrolling page.
	func aetherAmbientBackground(
		base: AetherAmbientBackground.Base = .standard
	) -> some View {
		background { AetherAmbientBackground(base: base) }
	}
}
