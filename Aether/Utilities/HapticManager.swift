//
//  HapticManager.swift
//  Aether
//

import UIKit

public enum HapticStrength: Int, CaseIterable, Identifiable {
	case light = 0
	case medium = 1
	case heavy = 2

	public var id: Int { rawValue }

	public var title: String {
		switch self {
		case .light: return .localized("Light")
		case .medium: return .localized("Medium")
		case .heavy: return .localized("Heavy")
		}
	}

	public var impactStyle: UIImpactFeedbackGenerator.FeedbackStyle {
		switch self {
		case .light: return .light
		case .medium: return .medium
		case .heavy: return .heavy
		}
	}
}

public final class HapticManager {
	public static let shared = HapticManager()
	public static let preferenceKey = "Aether.hapticStrength"

	private init() {}

	public var currentStrength: HapticStrength {
		let raw = UserDefaults.standard.integer(forKey: Self.preferenceKey)
		return HapticStrength(rawValue: raw) ?? .light
	}

	public func impact(_ overrideStrength: HapticStrength? = nil) {
		let style = (overrideStrength ?? currentStrength).impactStyle
		let generator = UIImpactFeedbackGenerator(style: style)
		generator.prepare()
		generator.impactOccurred()
	}

	public func selection() {
		// When using selection feedback, use the user's preferred impact feel for consistency
		impact()
	}

	public func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
		let generator = UINotificationFeedbackGenerator()
		generator.prepare()
		generator.notificationOccurred(type)
	}
}
