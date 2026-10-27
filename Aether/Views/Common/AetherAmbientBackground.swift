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
	@AppStorage("Aether.ambientBackgroundVerticalReach") private var verticalReach = 0.0
	@AppStorage("Aether.userTintColor") private var themeHex = "#848ef9"
	@Environment(\.colorScheme) private var colorScheme

	var base: Base = .standard

	private var accent: Color { Color(hex: themeHex) }

	var body: some View {
		ZStack {
			Color(uiColor: base.color)

			if isEnabled && colorScheme == .dark {
				GeometryReader { geometry in
					let normalizedReach = CGFloat(min(max(verticalReach, 0), 1))
					let glowRadius: CGFloat = 450
					let midpointRadius = glowRadius * 0.5
					let gradientCenterOffset = geometry.size.height * 0.04
					// At full reach, the gradient's visible midpoint reaches the
					// bottom edge. The previous diagonal-radius calculation put the
					// bottom near the transparent end of the gradient instead.
					let maximumVerticalScale = max(
						1,
						geometry.size.height / max(midpointRadius - gradientCenterOffset, 1)
					)
					let verticalScale = 1 + normalizedReach * (maximumVerticalScale - 1)
					let topGlow = RadialGradient(
						stops: [
							.init(color: accent.opacity(0.15), location: 0),
							.init(color: accent.opacity(0.045), location: 0.5),
							.init(color: .clear, location: 1)
						],
						center: UnitPoint(x: 0.5, y: -0.04),
						startRadius: 0,
						endRadius: glowRadius
					)

					ZStack {
						Group {
							if verticalScale == 1 {
								topGlow
							} else {
								// Keep the top edge pinned while extending the glow down;
								// scaling around the offscreen gradient center exposed the
								// black base layer above the shifted gradient.
								topGlow.scaleEffect(x: 1, y: verticalScale, anchor: .top)
							}
						}

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
