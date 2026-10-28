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

	public var intensity: CGFloat {
		switch self {
		case .light: return 0.35
		case .medium: return 0.65
		case .heavy: return 1.0
		}
	}
}

@MainActor
public final class HapticManager {
	public static let shared = HapticManager()
	public static let preferenceKey = "Aether.hapticStrength"

	private let generator = UIImpactFeedbackGenerator(style: .rigid)

	private init() {}

	public var currentStrength: HapticStrength {
		let raw = (UserDefaults.standard.object(forKey: Self.preferenceKey) as? NSNumber)?.intValue
		return raw.flatMap(HapticStrength.init(rawValue:)) ?? .medium
	}

	public func impact(_ overrideStrength: HapticStrength? = nil) {
		let intensity = (overrideStrength ?? currentStrength).intensity
		generator.prepare()
		generator.impactOccurred(intensity: intensity)
	}

	public func selection() {
		// Selection uses the same single crisp click and global intensity.
		impact()
	}

}
