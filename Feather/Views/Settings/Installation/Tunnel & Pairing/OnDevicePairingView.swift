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
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
			.navigationTitle(.localized("Pair This Device"))
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

			VStack(alignment: .leading, spacing: 8) {
				Text(.localized("Feather is ready to pair."))
					.font(.title3.weight(.semibold))
				Text(.localized("Open Developer Mode, choose Pair with Feather, then enter your passcode. Feather will finish pairing automatically."))
					.foregroundStyle(.secondary)
			}

			Button(.localized("Open Developer Mode")) {
				_openDeveloperMode()
			}
			.buttonStyle(.borderedProminent)

			Text(.localized("Feather stays active while Settings completes the secure pairing."))
				.font(.footnote)
				.foregroundStyle(.secondary)
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
				Text(.localized("No pairing code is needed. Keep Developer Mode open while Feather completes the connection."))
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
				Text(.localized("After confirming your passcode, paste this code to finish pairing. It was copied automatically."))
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

			Button(.localized("Open Developer Mode")) {
				_openDeveloperMode()
			}
			.buttonStyle(.borderedProminent)
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

	private func _openDeveloperMode() {
		pairing.prepareForSettings()
		guard let developerModeURL = URL(string: "App-Prefs:root=Privacy&path=DEVELOPER_MODE") else { return }
		UIApplication.shared.open(developerModeURL) { didOpen in
			guard !didOpen, let appSettingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
			UIApplication.shared.open(appSettingsURL)
		}
	}
}
