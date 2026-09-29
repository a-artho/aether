//
//  SettingsIconBadge.swift
//  Feather
//
//  Created by samara on 28.09.2026.
//

import SwiftUI

struct SettingsIconBadge: View {
	let systemImage: String
	var backgroundColor: Color = .blue
	var iconSize: CGFloat = 15

	var body: some View {
		ZStack {
			RoundedRectangle(cornerRadius: 6.5, style: .continuous)
				.fill(backgroundColor)
			Image(systemName: systemImage)
				.font(.system(size: iconSize, weight: .semibold))
				.foregroundColor(.white)
		}
		.frame(width: 29, height: 29)
	}

	static func color(for systemImage: String) -> Color {
		switch systemImage {
		case let s where s.contains("trash") || s.contains("xmark") || s.contains("octagon"):
			return .red
		case let s where s.contains("arrow.down") || s.contains("checkmark") || s.contains("network") || s.contains("speedometer"):
			return .green
		case let s where s.contains("signature") || s.contains("ruler") || s.contains("counterclockwise") || s.contains("pencil") || s.contains("lifepreserver"):
			return .orange
		case let s where s.contains("doc.badge.gearshape") || s.contains("checklist") || s.contains("person.text"):
			return .purple
		case let s where s.contains("gamecontroller") || s.contains("app.badge"):
			return .indigo
		case let s where s.contains("archivebox"):
			return .cyan
		case let s where s.contains("character.bubble") || s.contains("bubble"):
			return .teal
		case let s where s.contains("music") || s.contains("syringe"):
			return .pink
		case let s where s.contains("18.circle"):
			return .gray
		case let s where s.contains("shield") || s.contains("folder") || s.contains("iphone") || s.contains("paintpalette") || s.contains("server"):
			return .blue
		default:
			return .blue
		}
	}
}

struct SettingsRowLabel: View {
	let title: String
	let systemImage: String
	var backgroundColor: Color = .blue
	var iconSize: CGFloat = 15
	var textColor: Color = .primary

	init(
		_ title: String,
		systemImage: String,
		backgroundColor: Color = .blue,
		iconSize: CGFloat = 15,
		textColor: Color = .primary
	) {
		self.title = title
		self.systemImage = systemImage
		self.backgroundColor = backgroundColor
		self.iconSize = iconSize
		self.textColor = textColor
	}

	var body: some View {
		HStack(spacing: 12) {
			SettingsIconBadge(
				systemImage: systemImage,
				backgroundColor: backgroundColor,
				iconSize: iconSize
			)
			Text(title)
				.foregroundColor(textColor)
		}
	}
}
