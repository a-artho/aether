//
//  FRButton.swift
//  Aether
//
//  Created by samara on 16.04.2025.
//

import SwiftUI
import NimbleExtensions

public struct NBButton: View {
	private var _title: String
	private var _icon: String
	private var _style: NBToolbarMenuStyle
	private var _isLoading: Bool
	private var _showsBackground: Bool
	private var _horizontalPadding: CGFloat
	
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
				.background(Self.textPillBackground.opacity(_showsBackground ? 1 : 0))
				.clipShape(Capsule())
				.frame(minHeight: 44)
				.contentShape(Rectangle())
		}
	}
}
