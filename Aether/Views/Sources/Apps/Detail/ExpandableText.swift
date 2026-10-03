//
//  ExpandableText.swift
//  Aether
//
//  Created by samsam on 7/26/25.
//


import SwiftUI

enum SourceAppBodyText {
	static func replacingEmoji(in text: String) -> String {
		text.map { character in
			let scalars = character.unicodeScalars
			// Work on complete characters so flags, skin tones and joined emoji
			// become one dot. Plain digits and text symbols stay intact.
			let isEmoji = scalars.contains { $0.properties.isEmojiPresentation }
				|| (scalars.contains { $0.properties.isEmoji }
					&& scalars.contains { $0.value == 0xFE0F || $0.value == 0x20E3 })
			return isEmoji ? "·" : String(character)
		}.joined()
	}

	static func matches(_ first: String, _ second: String?) -> Bool {
		guard let second else { return false }
		func normalized(_ text: String) -> String {
			text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
		}
		return normalized(first) == normalized(second)
	}
}

struct ExpandableText: View {
	let text: String
	let lineLimit: Int
	var textStyle: Font.TextStyle = .body

	@State private var expanded: Bool = false
	@State private var truncated: Bool = false

	var body: some View {
		let displayText = SourceAppBodyText.replacingEmoji(in: text)
		VStack(alignment: .leading, spacing: 4) {
			Text(displayText)
				.font(.system(textStyle))
				.foregroundStyle(.secondary)
				.lineSpacing(3)
				.lineLimit(expanded ? nil : lineLimit)
				.background(
					Text(displayText)
						.font(.system(textStyle))
						.lineSpacing(3)
						.lineLimit(lineLimit)
						.background(GeometryReader { proxy in
							Color.clear
								.onAppear {
									let totalHeight = proxy.size.height
									let lineHeight = UIFont.preferredFont(
										forTextStyle: textStyle == .subheadline ? .subheadline : .body
									).lineHeight
									truncated = totalHeight > lineHeight * CGFloat(lineLimit)
								}
						})
						.hidden()
				)
				.onTapGesture {
					withAnimation {
						expanded.toggle()
					}
				}

			if truncated {
				Button(action: {
					withAnimation {
						expanded.toggle()
					}
				}) {
					Text(expanded ? .localized("Less") : .localized("More"))
						.font(.subheadline.weight(.medium))
						.foregroundColor(.accentColor)
				}
			}
		}
	}
}
