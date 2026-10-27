//
//  FRButton.swift
//  Aether
//
//  Created by samara on 16.04.2025.
//

import SwiftUI
import NimbleExtensions

public enum NBButtonSurfaceStyle: String, CaseIterable, Identifiable {
	case standard, glass

	public var id: Self { self }

	public var title: String {
		switch self {
		case .standard: .localized("Default")
		case .glass: .localized("Glass")
		}
	}
}

private struct NBButtonSurfaceStyleKey: EnvironmentKey {
	static let defaultValue = NBButtonSurfaceStyle.standard
}

public extension EnvironmentValues {
	var nbButtonSurfaceStyle: NBButtonSurfaceStyle {
		get { self[NBButtonSurfaceStyleKey.self] }
		set { self[NBButtonSurfaceStyleKey.self] = newValue }
	}
}

public struct NBButton: View {
	private var _title: String
	private var _icon: String
	private var _style: NBToolbarMenuStyle
	private var _isLoading: Bool
	private var _showsBackground: Bool
	private var _horizontalPadding: CGFloat
	@Environment(\.nbButtonSurfaceStyle) private var _surfaceStyle
	
	public init(
		_ title: String = "",
		systemImage: String = "",
		style: NBToolbarMenuStyle = .icon,
		horizontalPadding: CGFloat = 12,
		isLoading: Bool = false,
		showsBackground: Bool = true
	) {
		self._showsBackground = showsBackground
		self._isLoading = isLoading
		self._title = title
		self._icon = systemImage
		self._style = style
		self._horizontalPadding = horizontalPadding
	}

	public static var textPillBackground: Color {
		Color.accentColor.opacity(0.2)
	}
	
	public var body: some View {
		switch _style {
		case .icon:
			Image(systemName: _icon)
				.font(.caption).bold()
				.frame(width: 35, height: 35)
				.background(Color(uiColor: .quaternarySystemFill).opacity(_showsBackground ? 1 : 0))
				.clipShape(Circle())
				.frame(minWidth: 44, minHeight: 44)
				.contentShape(Rectangle())
			
		case .text:
			HStack(spacing: 6) {
					if _isLoading {
						ProgressView().controlSize(.mini)
					}
					ZStack {
                        // Every compact text pill shares Install's intrinsic minimum.
                        // Localization and Dynamic Type participate in measurement.
                        Text(String.localized("Install")).font(.footnote).bold()
                            .hidden().accessibilityHidden(true)
                        Text(_title).font(.footnote).bold()
                            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    }
				}
				.padding(.horizontal, _horizontalPadding)
				.frame(height: 35)
				.modifier(TextPillSurface(style: _surfaceStyle, showsBackground: _showsBackground))
				.frame(minHeight: 44)
				.contentShape(Rectangle())
		}
	}
}

private struct TextPillSurface: ViewModifier {
	let style: NBButtonSurfaceStyle
	let showsBackground: Bool

	@ViewBuilder
	func body(content: Content) -> some View {
		switch style {
		case .standard:
			content
				.background(NBButton.textPillBackground.opacity(showsBackground ? 1 : 0))
				.clipShape(Capsule())
		case .glass:
			if showsBackground {
				if #available(iOS 26.0, *) {
					content.glassEffect(.regular.interactive(), in: Capsule())
				} else {
					content
						.background(NBButton.textPillBackground)
						.clipShape(Capsule())
				}
			} else {
				content
			}
		}
	}
}
