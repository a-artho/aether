//
//  ExpandableText.swift
//  Aether
//
//  Created by samsam on 7/26/25.
//


import SwiftUI

enum SourceAppBodyText {
	private final class DisplayText: NSObject {
		let cleaned: String
		let body: String?
		let subtitle: String?
		init(_ raw: String) {
			cleaned = cleanEmoji(in: raw)
			body = cleaned.contains { !$0.isWhitespace && $0 != "·" && $0 != "•" } ? cleaned : nil
			subtitle = body?.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
		}
	}

	private final class Cache: NSCache<NSString, DisplayText>, @unchecked Sendable {}
	private static let cache: Cache = {
		let cache = Cache()
		cache.countLimit = 512
		cache.totalCostLimit = 4 * 1024 * 1024
		return cache
	}()

	private static func displayText(_ text: String) -> DisplayText {
		let key = text as NSString
		if let cached = cache.object(forKey: key) { return cached }
		let value = DisplayText(text)
		cache.setObject(value, forKey: key, cost: (text.utf16.count + value.cleaned.utf16.count + (value.subtitle?.utf16.count ?? 0)) * 2)
		return value
	}

	/// Catalog projections call this on their actor, before rows reach the UI.
	static func prepare(body: String?, subtitle: String?) {
		if let body { _ = displayText(body) }
		if let subtitle, subtitle != body { _ = displayText(subtitle) }
	}

	static func replacingEmoji(in text: String) -> String { displayText(text).cleaned }

	private static func cleanEmoji(in text: String) -> String {
		var result = ""
		result.reserveCapacity(text.utf8.count)
		var whitespace = ""
		for character in text {
			if character.isWhitespace {
				if character.isNewline {
					if whitespace.last == " " { whitespace.removeLast() }
					whitespace.append("\n")
				} else if whitespace.last != " " && whitespace.last != "\n" {
					whitespace.append(" ")
				}
				continue
			}
			let scalars = character.unicodeScalars
			let explicitEmoji = scalars.contains { $0.value == 0xFE0F || $0.value == 0x20E3 }
			let explicitText = scalars.contains { $0.value == 0xFE0E }
			// Complete characters cover flags, skin tones, keycaps and joined families.
			// Plain digits/#/* and copyright/trademark text are not emoji sequences.
			let isEmoji = !explicitText && scalars.contains {
				$0.properties.isEmoji && (explicitEmoji || ($0.value > 0x7F
					&& ![0x00A9, 0x00AE, 0x2122].contains($0.value)))
			}
			if isEmoji || character == "·" || character == "•" {
				if result.last == "·" || result.last == "•" {
					// Whitespace between adjacent emoji belongs to the same separator run.
					whitespace.removeAll(keepingCapacity: true)
					continue
				}
				if whitespace.contains("\n") { result.append(whitespace) }
				else if !result.isEmpty && result.last != "\n" { result.append(" ") }
				whitespace.removeAll(keepingCapacity: true)
				result.append(isEmoji ? "·" : character)
			} else {
				if !whitespace.isEmpty {
					if !result.isEmpty { result.append(whitespace) }
					whitespace.removeAll(keepingCapacity: true)
				} else if result.last == "·" || result.last == "•" {
					result.append(" ")
				}
				result.append(character)
			}
		}
		return result.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	static func body(in text: String?) -> String? {
		text.flatMap { displayText($0).body }
	}

	static func subtitle(in text: String?, followingVersion: Bool) -> String? {
		guard var line = text.flatMap({ displayText($0).subtitle }) else { return nil }
		if followingVersion && (line.hasPrefix("· ") || line.hasPrefix("• ")) { line.removeFirst(2) }
		return line
	}

	static func matches(_ first: String, _ second: String?) -> Bool {
		guard let second else { return false }
		func normalized(_ text: String) -> String {
			replacingEmoji(in: text).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
		}
		return normalized(first) == normalized(second)
	}
}

struct ExpandableText: View {
	let text: String
	let lineLimit: Int
	var textStyle: Font.TextStyle = .body

	@State private var expanded: Bool = false
	@State private var constrainedHeight: CGFloat = 0
	@State private var fullHeight: CGFloat = 0

	private var truncated: Bool { fullHeight > constrainedHeight + 1 }

	var body: some View {
		let displayText = SourceAppBodyText.replacingEmoji(in: text)
		VStack(alignment: .leading, spacing: 4) {
			Text(displayText)
				.font(.system(textStyle))
				.foregroundStyle(.secondary)
				.lineSpacing(3)
				.lineLimit(expanded ? nil : lineLimit)
				.background {
					Text(displayText)
						.font(.system(textStyle))
						.lineSpacing(3)
						.lineLimit(lineLimit)
						.fixedSize(horizontal: false, vertical: true)
						.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { constrainedHeight = $0 }
						.hidden()
					Text(displayText)
						.font(.system(textStyle))
						.lineSpacing(3)
						.lineLimit(nil)
						.fixedSize(horizontal: false, vertical: true)
						.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
						.hidden()
				}
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
