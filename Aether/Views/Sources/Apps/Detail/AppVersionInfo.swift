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
	let textStyle: Font.TextStyle

	init(
		version: String,
		date: Date? = nil,
		description: String,
		isPlaceholder: Bool = false,
		textStyle: Font.TextStyle = .body
	) {
		self.version = version
		self.date = date
		self.description = description
		self.isPlaceholder = isPlaceholder
		self.textStyle = textStyle
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			if isPlaceholder {
				Text(SourceAppBodyText.replacingEmoji(in: description))
					.font(.system(textStyle))
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			} else {
				ExpandableText(
					text: description,
					lineLimit: 3,
					textStyle: textStyle
				)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}
