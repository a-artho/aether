//
//  FlexibleHeader.swift
//  Aether
//
//  Created by samsam on 7/25/25.
//

import SwiftUI

@Observable private class FlexibleHeaderGeometry {
	var offset: CGFloat = 0
	var windowHeight: CGFloat = 0
}

/// A view modifier that stretches content when the containing geometry offset changes.
private struct FlexibleHeaderContentModifier: ViewModifier {
	@Environment(FlexibleHeaderGeometry.self) private var geometry

	func body(content: Content) -> some View {
		let height = (geometry.windowHeight / 3.2) - geometry.offset
		content
			.frame(height: height)
			.padding(.bottom, geometry.offset)
			.offset(y: geometry.offset)
	}
}

/// A view modifier that tracks scroll geometry and window size to update header behavior.
private struct FlexibleHeaderScrollViewModifier: ViewModifier {
	@State private var geometry = FlexibleHeaderGeometry()

	func body(content: Content) -> some View {
		content
			.onScrollGeometryChange(for: CGFloat.self) { geometry in
				min(geometry.contentOffset.y + geometry.contentInsets.top, 0)
			} action: { _, offset in
				geometry.offset = offset
			}
			.onGeometryChange(for: CGSize.self) { geometry in
				geometry.size
			} action: {
				geometry.windowHeight = $0.height
			}
			.environment(geometry)
	}
}

// MARK: - View Extensions

extension ScrollView {
	@ViewBuilder
	@MainActor func flexibleHeaderScrollView() -> some View {
		modifier(FlexibleHeaderScrollViewModifier())
	}
}

extension View {
	@ViewBuilder
	func flexibleHeaderContent() -> some View {
		modifier(FlexibleHeaderContentModifier())
	}
	
	@ViewBuilder
	func shouldSetInset() -> some View {
		self.ignoresSafeArea(edges: .top)
	}
}
