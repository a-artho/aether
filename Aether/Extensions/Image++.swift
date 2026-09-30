//
//  Image+appIconStyle.swift
//  Aether
//
//  Created by samara on 11.04.2025.
//

import SwiftUI

extension Image {
	/// Applies a standard icon style with firmware-aware corner radius
	func appIconStyle(
		size: CGFloat = 50,
		lineWidth: CGFloat = 1,
		isCircle: Bool = false,
		background: Color = .clear
	) -> some View {
		let multiplier: CGFloat = 0.2677
		
		let radius = isCircle ? (size / 2) : (size * multiplier)
		
		return self.resizable()
			.scaledToFit()
			.frame(width: size, height: size)
			.background(
				RoundedRectangle(cornerRadius: radius, style: .continuous)
					.fill(background)
			)
			.overlay {
				RoundedRectangle(cornerRadius: radius, style: .continuous)
					.strokeBorder(Color.primary.opacity(0.15), lineWidth: lineWidth)
			}
			.clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
	}
}
