import SwiftUI
import IDeviceSwift
import NimbleViews

struct ActiveInstallationRow: View {
	@ObservedObject private var installationManager = AppInstallationManager.shared
	let app: AppInfoPresentable
	@ObservedObject var viewModel: InstallerStatusViewModel
	var showsActions = true

	var body: some View {
		InstallationRowContent(
			app: app,
			statusLabel: installationManager.isFinishingInstallation ? .localized("Finishing Installation") : viewModel.statusLabel,
			statusColor: _statusColor,
			errorMessage: _errorMessage
		) {
			if _errorMessage != nil {
				Button {
					installationManager.retryActiveInstall()
				} label: {
					InstallationProgressRing(progress: nil, systemImage: "arrow.clockwise")
				}
				.buttonStyle(.borderless)
				.accessibilityLabel(.localized("Retry"))
			} else {
				InstallationProgressRing(
					progress: viewModel.isCompleted ? 1 : _progress,
					systemImage: viewModel.statusImage
				)
				.accessibilityElement(children: .ignore)
				.accessibilityLabel(viewModel.statusLabel)
				.accessibilityValue(Text(_progress, format: .percent.precision(.fractionLength(0))))
			}
		}
		.modifier(InstallationCancellationActions(enabled: showsActions, isDisabled: installationManager.isFinishingInstallation, completed: viewModel.isCompleted) { installationManager.cancel() })
		.contextMenu {
			if showsActions {
				if _errorMessage != nil {
					Button(.localized("Retry"), systemImage: "arrow.clockwise") {
						installationManager.retryActiveInstall()
					}
				}
				Button(viewModel.isCompleted ? .localized("Dismiss") : .localized("Cancel"), systemImage: "xmark", role: .destructive) {
					installationManager.cancel()
				}.disabled(installationManager.isFinishingInstallation)
			}
		}
		.sheet(isPresented: $installationManager.isWebviewPresenting) {
			if let installer = installationManager.installer {
				SafariRepresentableView(url: installer.pageEndpoint).ignoresSafeArea()
			}
		}
	}

	private var _progress: Double { viewModel.operationProgress }

	private var _errorMessage: String? {
		if case .broken(let error) = viewModel.status {
			return error is InstallationBackgroundError ? .localized("iOS interrupted background installation") : error.localizedDescription
		}
		return nil
	}

	private var _statusColor: Color {
		switch viewModel.status {
		case .completed: .green
		case .broken: .red
		case .installing: .accentColor
		default: .secondary
		}
	}
}

struct QueuedInstallationRow: View {
	let request: AppInstallationManager.InstallationRequest
	let cancel: () -> Void
	var showsActions = true

	var body: some View {
		InstallationRowContent(app: request.app, statusLabel: .localized("Queued"), statusColor: .secondary) {
			InstallationProgressRing(progress: nil, systemImage: "clock")
				.accessibilityHidden(true)
		}
		.modifier(InstallationCancellationActions(enabled: showsActions, cancel: cancel))
		.contextMenu {
			if showsActions {
				Button(.localized("Cancel"), systemImage: "xmark", role: .destructive, action: cancel)
			}
		}
	}
}

private struct InstallationRowContent<Accessory: View>: View {
	let app: AppInfoPresentable
	let statusLabel: String
	let statusColor: Color
	var errorMessage: String? = nil
	@ViewBuilder var accessory: () -> Accessory

	var body: some View {
		HStack(spacing: 18) {
			FRAppIconView(app: app, size: 50)
			VStack(alignment: .leading, spacing: 2) {
				Text(app.name ?? .localized("Unknown"))
					.font(.headline)
					.lineLimit(1)
				Text(subtitle)
					.font(.caption)
					.foregroundStyle(.secondary)
					.lineLimit(1)
				Text(errorMessage ?? statusLabel)
					.font(.system(size: 13, weight: .medium))
					.foregroundStyle(statusColor)
					.lineLimit(errorMessage == nil ? 1 : 2)
			}
			.padding(.vertical, 2)
			.frame(maxWidth: .infinity, alignment: .leading)
			accessory()
		}
		.contentShape(Rectangle())
	}

	private var subtitle: String {
		if let version = app.version, let id = app.identifier { return "\(version) • \(id)" }
		return app.identifier ?? .localized("Preparing")
	}
}

struct InstallationProgressRing: View {
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	let progress: Double?
	let systemImage: String

	var body: some View {
		ZStack {
			Circle()
				.stroke(Color.accentColor.opacity(0.2), lineWidth: 2.3)
			if let progress {
				Circle()
					.trim(from: 0, to: progress)
					.stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.3, lineCap: .round))
					.rotationEffect(.degrees(-90))
					.animation(reduceMotion ? nil : .smooth, value: progress)
			}
			Image(systemName: systemImage)
				.contentTransition(.symbolEffect(.replace))
				.foregroundStyle(Color.accentColor)
				.font(.footnote.bold())
		}
		.frame(width: 31, height: 31)
		.frame(width: 44, height: 44)
	}
}

private struct InstallationCancellationActions: ViewModifier {
	var enabled = true
	var isDisabled = false
	var completed = false
	let cancel: () -> Void

	func body(content: Content) -> some View {
		content
			.swipeActions(edge: .trailing, allowsFullSwipe: true) {
				if enabled {
					Button(completed ? .localized("Dismiss") : .localized("Cancel"), systemImage: "xmark", role: .destructive, action: cancel)
						.disabled(isDisabled)
				}
			}
			.accessibilityAction(named: Text(completed ? .localized("Dismiss") : .localized("Cancel"))) { if enabled && !isDisabled { cancel() } }
	}
}
