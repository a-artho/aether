import SwiftUI
import IDeviceSwift
import NimbleExtensions

enum DeviceControlsStyle: String, CaseIterable, Identifiable {
	case standard, liquidGlass, nativeRaised
	var id: Self { self }
	var title: String {
		switch self {
		case .standard: .localized("Default")
		case .liquidGlass: .localized("Glass")
		case .nativeRaised: .localized("Native")
		}
	}
}

struct SettingsDeviceControls: View {
	@AppStorage("Aether.installationMethod") private var installationMethod = 0
	@AppStorage("Aether.spoofing.simulationMayBeActive") private var isSpoofingActive = false
	@ObservedObject private var connection = DeviceConnectionManager.shared
	let certificate: CertificatePair?
	let openTunnel: () -> Void
	let openPairing: () -> Void
	let openSpoofing: () -> Void
	let openCertificates: () -> Void

	private var canOpenSpoofing: Bool {
		installationMethod == 1 && connection.isConnected && !connection.isUpdating
	}

	private var tunnelStatus: String {
		if installationMethod != 1 { return .localized("Local only") }
		if connection.isUpdating { return .localized("Connecting…") }
		if connection.isConnected { return .localized("Connected") }
		if !connection.hasPairingFile { return .localized("Pairing needed") }
		if connection.requiresInAppTunnelSetup { return .localized("Setup needed") }
		return .localized("Disconnected")
	}

	private var spoofingStatus: String {
		if installationMethod != 1 { return .localized("Local only") }
		if isSpoofingActive { return .localized("Active") }
		return canOpenSpoofing ? .localized("Ready") : .localized("Tunnel needed")
	}

	private var pairingStatus: String {
		if installationMethod != 1 { return .localized("Local only") }
		guard connection.hasPairingFile else { return .localized("Not paired") }
		switch connection.pairingVerification.status {
		case .verified where connection.isConnected: return .localized("Verified")
		case .checking: return .localized("Checking…")
		case .unableToVerify: return .localized("Not verified")
		default: return .localized("Unverified")
		}
	}

	var body: some View {
		VStack(spacing: 12) {
			HStack(spacing: 12) {
				DeviceAccessoryTile(title: .localized("Tunnel"), subtitle: tunnelStatus,
					systemImage: "network", isActive: installationMethod == 1 && connection.isConnected,
					isDisabled: installationMethod != 1, action: openTunnel)
				DeviceAccessoryTile(title: .localized("Pairing"), subtitle: pairingStatus,
					systemImage: "key.fill", isActive: installationMethod == 1 && connection.isConnected && connection.pairingVerification.status == .verified,
					isDisabled: installationMethod != 1, action: openPairing)
			}
			HStack(spacing: 12) {
				DeviceAccessoryTile(title: .localized("Spoofing"), subtitle: spoofingStatus,
					systemImage: "location.fill", isActive: isSpoofingActive,
					isDisabled: !canOpenSpoofing, action: openSpoofing)
				if let certificate {
					CertificateControlTile(certificate: certificate, action: openCertificates)
				} else {
					DeviceAccessoryTile(title: .localized("Certificate"), subtitle: .localized("Not selected"), action: openCertificates) {
						Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2.5)
							.frame(width: 15, height: 15)
					}
				}
			}
		}
	}
}

private struct DeviceAccessoryTile<Icon: View>: View {
	@AppStorage("Aether.deviceControlsStyle") private var controlsStyle: DeviceControlsStyle = .standard
	let title: String
	let subtitle: String
	var isDisabled = false
	let action: () -> Void
	@ViewBuilder var icon: () -> Icon

	var body: some View {
		button.buttonStyle(.borderless).tint(Color.primary)
	}

	private var button: some View {
		Button {
			HapticManager.shared.impact()
			action()
		} label: {
			HStack(spacing: 8) {
				icon().frame(width: 24, height: 24).accessibilityHidden(true)

				VStack(alignment: .leading, spacing: 2) {
					Text(title)
						.font(.subheadline.weight(.semibold))
						.foregroundStyle(Color.primary)
						.fixedSize(horizontal: false, vertical: true)

					Text(subtitle)
						.font(.caption2.weight(.medium))
						.foregroundStyle(Color.secondary)
						.fixedSize(horizontal: false, vertical: true)
				}

				Spacer(minLength: 0)
				Image(systemName: "chevron.right")
					.font(.caption2.weight(.semibold))
					.foregroundStyle(Color.secondary.opacity(0.6))
					.accessibilityHidden(true)
			}
			.padding(.horizontal, 10)
			.padding(.vertical, 8)
			.frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
			.background(controlsStyle == .standard ? Color(uiColor: .secondarySystemGroupedBackground) : Color.clear,
				in: RoundedRectangle(cornerRadius: 15, style: .continuous))
			.contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
		}
		.disabled(isDisabled)
		.opacity(isDisabled ? 0.6 : 1.0)
	}
}

private struct DeviceTileSymbol: View {
	let name: String
	let active: Bool
	let disabled: Bool
	let activeColor: Color
	var body: some View {
		Image(systemName: name)
			.font(.system(size: 15, weight: .semibold))
			.foregroundStyle(active ? activeColor : Color.secondary.opacity(disabled ? 0.55 : 1))
	}
}

private extension DeviceAccessoryTile where Icon == DeviceTileSymbol {
	init(title: String, subtitle: String, systemImage: String, isActive: Bool = false,
		 activeColor: Color = .green, isDisabled: Bool = false, action: @escaping () -> Void) {
		self.init(title: title, subtitle: subtitle, isDisabled: isDisabled, action: action) {
			DeviceTileSymbol(name: systemImage, active: isActive, disabled: isDisabled, activeColor: activeColor)
		}
	}
}

private struct CertificateControlTile: View {
	@ObservedObject var certificate: CertificatePair
	let action: () -> Void
	@State private var creationDate: Date?

	var body: some View {
		TimelineView(.periodic(from: .now, by: 60)) { context in
			let expiration = certificate.expiration
			let remaining = expiration?.timeIntervalSince(context.date) ?? 0
			let revoked = certificate.revoked == true
			let expired = expiration != nil && remaining <= 0
			let color: Color = revoked || expired ? .red : expiration == nil ? .secondary : remaining < 30 * 86400 ? .orange : .green
			let total = creationDate.flatMap { start in expiration.map { $0.timeIntervalSince(start) } } ?? 0
			let fraction = total > 0 ? min(1, max(0, remaining / total)) : 0
			let subtitle = revoked ? String.localized("Revoked") : expiration?.expirationInfo(from: context.date).formatted ?? String.localized("Unknown")
			DeviceAccessoryTile(title: .localized("Certificate"), subtitle: subtitle, action: action) {
				ZStack {
					Circle().stroke(color.opacity(0.18), lineWidth: 2.5)
					Circle().trim(from: 0, to: revoked || expired ? 1 : fraction)
						.stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
						.rotationEffect(.degrees(-90))
				}
				.frame(width: 15, height: 15)
			}
		}
		.task(id: certificate.uuid) {
			creationDate = Storage.shared.getProvisionFileDecoded(for: certificate)?.CreationDate
		}
	}
}
