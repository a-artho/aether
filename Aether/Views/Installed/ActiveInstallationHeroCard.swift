//
//  ActiveInstallationHeroCard.swift
//  Aether
//
//  Created by samara on 28.09.2026.
//

import SwiftUI
import IDeviceSwift
import NimbleViews

struct ActiveInstallationHeroCard: View {
	@ObservedObject var installationManager = AppInstallationManager.shared
	let app: AppInfoPresentable
	@ObservedObject var viewModel: InstallerStatusViewModel

	var body: some View {
		VStack(spacing: 12) {
			HStack(spacing: 14) {
				FRAppIconView(app: app, size: 52)

				VStack(alignment: .leading, spacing: 3) {
					Text(app.name ?? .localized("Unknown"))
						.font(.headline)
						.lineLimit(1)

					Text(_subtitle)
						.font(.caption)
						.foregroundColor(.secondary)
						.lineLimit(1)

					HStack(spacing: 6) {
						Image(systemName: viewModel.statusImage)
							.font(.system(size: 13, weight: .semibold))
							.foregroundColor(_statusColor)

						Text(viewModel.statusLabel)
							.font(.system(size: 13, weight: .medium))
							.foregroundColor(_statusColor)
					}
				}

				Spacer(minLength: 8)

				Button {
					installationManager.cancel()
				} label: {
					ZStack {
						Image(systemName: "xmark")
							.font(.system(size: 12, weight: .bold))
							.foregroundColor(.secondary)
							.frame(width: 28, height: 28)
							.background(Color(UIColor.tertiarySystemFill), in: Circle())
					}
					.frame(width: 44, height: 44)
					.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				.accessibilityLabel(.localized("Cancel Installation"))
			}

			// Progress bar row
			if !viewModel.isCompleted {
				if case .broken(let error) = viewModel.status {
					HStack(spacing: 6) {
						Image(systemName: "exclamationmark.circle.fill")
							.foregroundColor(.red)
						Text(error.localizedDescription)
							.font(.caption)
							.foregroundColor(.red)
							.lineLimit(2)
						Spacer()
						Button(.localized("Retry")) {
							installationManager.startInstall(app: app)
						}
						.font(.caption.bold())
					}
				} else {
					VStack(spacing: 4) {
						let currentProgress = max(viewModel.overallProgress, viewModel.installProgress)
						if currentProgress > 0 {
							ProgressView(value: currentProgress, total: 1.0)
								.progressViewStyle(.linear)
								.tint(Color.accentColor)

							HStack {
								Spacer()
								Text("\(Int(currentProgress * 100))%")
									.font(.system(size: 11, weight: .semibold, design: .rounded))
									.monospacedDigit()
									.foregroundColor(.secondary)
							}
						} else {
							ProgressView()
								.progressViewStyle(.linear)
								.tint(Color.accentColor)
						}
					}
				}
			}
		}
		.animation(.spring(response: 0.35, dampingFraction: 0.8), value: viewModel.statusLabel)
		.padding(14)
		.background(Color(UIColor.secondarySystemGroupedBackground))
		.clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
		.overlay(
			RoundedRectangle(cornerRadius: 16, style: .continuous)
				.stroke(Color.primary.opacity(0.06), lineWidth: 1)
		)
		.shadow(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 3)
		.sheet(isPresented: $installationManager.isWebviewPresenting) {
			if let installer = installationManager.installer {
				SafariRepresentableView(url: installer.pageEndpoint).ignoresSafeArea()
			}
		}
	}

	private var _subtitle: String {
		if let version = app.version, let id = app.identifier {
			return "\(version) • \(id)"
		} else if let id = app.identifier {
			return id
		} else {
			return .localized("Preparing")
		}
	}

	private var _statusColor: Color {
		switch viewModel.status {
		case .completed:
			return .green
		case .broken:
			return .red
		case .installing:
			return .accentColor
		default:
			return .secondary
		}
	}
}
