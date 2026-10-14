//
//  TabPlaceholderView.swift
//  Aether
//

import SwiftUI
import NimbleViews

/// A consistent empty-state treatment for Aether's top-level tabs.
struct TabPlaceholderView<Actions: View>: View {
	let title: String
	let description: String
	let systemImage: String
	private let actions: Actions

	init(
		title: String,
		description: String,
		systemImage: String,
		@ViewBuilder actions: () -> Actions
	) {
		self.title = title
		self.description = description
		self.systemImage = systemImage
		self.actions = actions()
	}

	var body: some View {
		VStack(spacing: 12) {
			Image(systemName: systemImage)
				.font(.system(size: 40))
				.foregroundStyle(.secondary)
			Text(title)
				.font(.headline)
				.foregroundStyle(.primary)
			Text(description)
				.nbFont(.subheadline)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
				.padding(.horizontal, 28)
			actions
				.padding(.top, 4)
		}
		.frame(maxWidth: .infinity)
		.padding(.vertical, 16)
	}
}

extension TabPlaceholderView where Actions == EmptyView {
	init(title: String, description: String, systemImage: String) {
		self.init(title: title, description: description, systemImage: systemImage) {
			EmptyView()
		}
	}
}
