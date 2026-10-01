//
//  AppVersionInfo.swift
//  Aether
//
//  Created by Nagata Asami on 27/7/25.
//

import SwiftUI

struct AppVersionInfo: View {
	let version: String
	let date: Date?
	let description: String
	let isPlaceholder: Bool

	init(
		version: String,
		date: Date? = nil,
		description: String,
		isPlaceholder: Bool = false
	) {
		self.version = version
		self.date = date
		self.description = description
		self.isPlaceholder = isPlaceholder
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			if isPlaceholder {
				Text(description)
					.font(.body)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			} else {
				ExpandableText(
					text: description,
					lineLimit: 3
				)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}
