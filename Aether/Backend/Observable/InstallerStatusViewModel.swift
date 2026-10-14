//
//  StatusViewModel.swift
//  Aether
//
//  Created by samara on 24.04.2025.
//

import Foundation
import Combine
import IDeviceSwift

extension InstallerStatusViewModel {
	/// Stage weights describe overall work, not an estimated time remaining.
	/// Signing never fills the ring early when installation follows it.
	var operationProgress: Double {
		if isCompleted { return 1 }
		func normalized(_ value: Double) -> Double {
			value.isFinite ? min(1, max(0, value)) : 0
		}
		let signingShare = signsBeforeInstalling ? 0.30 : 0.0
		if case .signing = status {
			return normalized(signingProgress) * (signsBeforeInstalling ? signingShare : 1)
		}
		let installation = isIDevice
			? normalized(packageProgress) * 0.25 + normalized(uploadProgress) * 0.45 + normalized(installProgress) * 0.30
			: normalized(packageProgress) * 0.45 + normalized(installProgress) * 0.55
		return min(0.99, signingShare + (1 - signingShare) * installation)
	}

	var statusImage: String {
		switch status {
		case .none: "archivebox.fill"
		case .signing: "signature"
		case .ready: "app.gift"
		case .sendingManifest, .sendingPayload: "paperplane.fill"
		case .installing: "square.and.arrow.down"
		case .completed: "app.badge.checkmark"
		case .broken: "exclamationmark.triangle.fill"
		}
	}
	
	var statusLabel: String {
		switch status {
		case .none: .localized("Packaging")
		case .signing: .localized("Signing")
		case .ready: .localized("Ready")
		case .sendingManifest: .localized("Sending Manifest")
		case .sendingPayload: .localized("Sending Payload")
		case .installing: .localized("Installing")
		case .completed: .localized("Completed")
		case .broken: .localized("Error")
		}
	}
}
