//
//  OnDevicePairingView.swift
//  Feather
//
//  Created by Feather.
//

import SwiftUI
import UIKit

struct OnDevicePairingView: View {
	@Environment(\.dismiss) private var dismiss
	@ObservedObject private var pairing = OnDevicePairingManager.shared

	var body: some View {
		NavigationStack {
			ScrollView {
				VStack(alignment: .leading, spacing: 20) {
					switch pairing.state {
					case .waitingForSettings:
						_waitingContent
					case .pairingWithoutCode:
						_pinlessContent
					case .awaitingCode(let code):
						_codeContent(code)
					case .cancelling:
						ProgressView(.localized("Closing secure pairing…"))
							.frame(maxWidth: .infinity, maxHeight: .infinity)
					case .completed:
						_completionContent
					case .failed(let message):
						_failureContent(message)
					case .idle:
						ProgressView()
							.frame(maxWidth: .infinity, maxHeight: .infinity)
					}
				}
				.padding(24)
				.frame(maxWidth: .infinity, alignment: .topLeading)
			}
			.navigationTitle(.localized("On-Device Pairing"))
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					if pairing.isActive {
						Button(.localized("Cancel")) {
							pairing.cancel()
						}
					} else {
						Button(.localized("Done")) {
							dismiss()
						}
					}
				}
			}
			.interactiveDismissDisabled(pairing.isActive)
			.onChange(of: pairing.state) { state in
				if case .idle = state {
					dismiss()
				}
			}
		}
	}

	private var _waitingContent: some View {
		VStack(alignment: .leading, spacing: 20) {
			Image(systemName: "iphone.and.arrow.forward")
				.font(.system(size: 34, weight: .semibold))
				.foregroundStyle(.blue)

			VStack(alignment: .leading, spacing: 6) {
				Text(.localized("Feather is ready to pair"))
					.font(.title3.weight(.semibold))
				Text(.localized("To pair this device, follow these steps in Settings:"))
					.font(.subheadline)
					.foregroundStyle(.secondary)
			}

			VStack(alignment: .leading, spacing: 14) {
				_instructionStep(
					number: 1,
					title: .localized("Open Settings"),
					detail: .localized("Tap the button below to switch to the Settings app.")
				)
				_instructionStep(
					number: 2,
					title: .localized("Go to Developer Mode"),
					detail: .localized("Navigate to Privacy & Security → Developer Mode.")
				)
				_instructionStep(
					number: 3,
					title: .localized("Pair with Feather"),
					detail: .localized("Choose Pair with Feather and enter your device passcode. Pairing will complete automatically.")
				)
			}
			.padding(.vertical, 4)

			Button {
				_openSettings()
			} label: {
				Text(.localized("Open Settings"))
					.frame(maxWidth: .infinity)
			}
			.buttonStyle(.borderedProminent)
			.controlSize(.large)

			Text(.localized("Feather stays active in the background while Settings completes the secure pairing."))
				.font(.footnote)
				.foregroundStyle(.secondary)
		}
	}

	private func _instructionStep(number: Int, title: String, detail: String) -> some View {
		HStack(alignment: .top, spacing: 12) {
			Text("\(number)")
				.font(.caption.weight(.bold))
				.foregroundStyle(.white)
				.frame(width: 22, height: 22)
				.background(Circle().fill(Color.blue))

			VStack(alignment: .leading, spacing: 2) {
				Text(title)
					.font(.subheadline.weight(.semibold))
					.foregroundStyle(.primary)

				Text(detail)
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
	}

	private var _pinlessContent: some View {
		VStack(alignment: .leading, spacing: 20) {
			Image(systemName: "lock.shield.fill")
				.font(.system(size: 34, weight: .semibold))
				.foregroundStyle(.green)

			VStack(alignment: .leading, spacing: 8) {
				Text(.localized("Finishing secure pairing"))
					.font(.title3.weight(.semibold))
				Text(.localized("No pairing code is needed. Keep Settings open in Developer Mode while Feather completes the connection."))
					.foregroundStyle(.secondary)
			}

			ProgressView()
				.controlSize(.large)
		}
	}

	private func _codeContent(_ code: String) -> some View {
		VStack(alignment: .leading, spacing: 20) {
			Image(systemName: "lock.shield.fill")
				.font(.system(size: 34, weight: .semibold))
				.foregroundStyle(.green)

			VStack(alignment: .leading, spacing: 8) {
				Text(.localized("Enter this code in Settings"))
					.font(.title3.weight(.semibold))
				Text(.localized("In Settings → Privacy & Security → Developer Mode, paste this pairing code after confirming your passcode. It was copied automatically."))
					.foregroundStyle(.secondary)
			}

			Text(code)
				.font(.system(size: 38, weight: .semibold, design: .monospaced))
				.tracking(5)
				.frame(maxWidth: .infinity)
				.padding(.vertical, 20)
				.background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

			Button(.localized("Copy Code")) {
				UIPasteboard.general.string = code
			}
			.buttonStyle(.bordered)

			Button {
				_openSettings()
			} label: {
				Text(.localized("Open Settings"))
					.frame(maxWidth: .infinity)
			}
			.buttonStyle(.borderedProminent)
			.controlSize(.large)
		}
	}

	private var _completionContent: some View {
		VStack(alignment: .leading, spacing: 16) {
			Image(systemName: "checkmark.circle.fill")
				.font(.system(size: 38, weight: .semibold))
				.foregroundStyle(.green)
			Text(.localized("Device paired"))
				.font(.title3.weight(.semibold))
			Text(.localized("Feather will use this pairing record for iDevice installs."))
				.foregroundStyle(.secondary)
		}
	}

	private func _failureContent(_ message: String) -> some View {
		VStack(alignment: .leading, spacing: 16) {
			Image(systemName: "exclamationmark.triangle.fill")
				.font(.system(size: 34, weight: .semibold))
				.foregroundStyle(.orange)
			Text(.localized("Pairing couldn’t finish"))
				.font(.title3.weight(.semibold))
			Text(message)
				.foregroundStyle(.secondary)
			Button(.localized("Try Again")) {
				pairing.begin()
			}
			.buttonStyle(.borderedProminent)
		}
	}

	private func _openSettings() {
		pairing.prepareForSettings()
		if let settingsURL = URL(string: "App-Prefs:"), UIApplication.shared.canOpenURL(settingsURL) {
			UIApplication.shared.open(settingsURL) { didOpen in
				guard !didOpen, let appSettingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
				UIApplication.shared.open(appSettingsURL)
			}
		} else if let appSettingsURL = URL(string: UIApplication.openSettingsURLString) {
			UIApplication.shared.open(appSettingsURL)
		}
	}
}
