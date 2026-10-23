import SwiftUI
import NimbleViews
import IDeviceSwift

struct InstalledAppInformationView: View {

	let summary: InstalledApp
	@State private var detailedApp: InstalledApp?
	@State private var metadataError: String?
	private var app: InstalledApp { detailedApp ?? summary }

	init(app: InstalledApp) { self.summary = app }
	@State private var copiedItemText: String?
	@State private var copyFeedbackGeneration = UUID()

	var body: some View {
		List {
			if detailedApp == nil {
				if let metadataError { Text(metadataError).foregroundStyle(.secondary) }
				else { ProgressView() }
			}
			Section(.localized("Specifications")) {
				_detailRow(label: .localized("Signer"), value: app.signerIdentity ?? .localized("Unavailable"))
				_detailRow(label: .localized("Bundle Identifier"), value: app.bundleIdentifier, isCopyable: true)
				if let version = app.version {
					let versionString = app.build.map { "\(version) (\($0))" } ?? version
					_detailRow(label: .localized("Version"), value: versionString)
				}
				if let container = app.containerPath {
					_detailRow(label: .localized("Data Container"), value: container, isCopyable: true)
				}
				if let bundle = app.bundlePath {
					_detailRow(label: .localized("Bundle Path"), value: bundle, isCopyable: true)
				}
				if let executable = app.executableName {
					_detailRow(label: .localized("Executable"), value: executable)
				}
				if let minimumOSVersion = app.minimumOSVersion {
					_detailRow(label: .localized("Minimum iOS"), value: "iOS \(minimumOSVersion)+")
				}
				_detailRow(label: .localized("Target Devices"), value: app.deviceFamilies.joined(separator: ", "))
				if let sdkName = app.sdkName {
					_detailRow(label: .localized("SDK"), value: sdkName)
				}
				if let xcodeBuild = app.xcodeBuild {
					_detailRow(label: .localized("Xcode Build"), value: xcodeBuild)
				}
				if !app.registeredUrlSchemes.isEmpty {
					VStack(alignment: .leading, spacing: 6) {
						Text(.localized("URL Schemes"))
							.font(.caption)
							.foregroundStyle(.secondary)

						ForEach(app.registeredUrlSchemes, id: \.self) { scheme in
							HStack {
								Text("\(scheme)://")
									.font(.system(.subheadline, design: .monospaced))
									.foregroundStyle(.primary)

								Spacer()

								Button {
									if let url = URL(string: "\(scheme)://") {
										UIApplication.shared.open(url)
									}
								} label: {
									Label(.localized("Open"), systemImage: "arrow.up.right")
										.font(.caption2.weight(.semibold))
										.foregroundStyle(.blue)
										.padding(.horizontal, 8)
										.padding(.vertical, 4)
										.background(Color.blue.opacity(0.12), in: Capsule())
								}
								.buttonStyle(.plain)
							}
						}
					}
					.padding(.vertical, 2)
				}
			}
			entitlementsSection
		}
		.task(id: summary.iconCacheVersion) {
			do {
				let info = try await InstallationAppProxy().fetchApps(applicationType: "User", bundleIdentifier: summary.bundleIdentifier)
				try Task.checkCancellation()
				guard let full = info.first(where: { $0.CFBundleIdentifier == summary.bundleIdentifier }) else {
					metadataError = .localized("App information is unavailable.")
					return
				}
				detailedApp = InstalledApp(bundleIdentifier: summary.bundleIdentifier, name: summary.name, version: full.CFBundleShortVersionString, build: full.CFBundleVersion, appInfo: full)
			} catch is CancellationError {} catch { metadataError = error.localizedDescription }
		}
		.listStyle(.insetGrouped)
		.navigationTitle(app.displayName)
		.navigationBarTitleDisplayMode(.inline)

		.overlay(alignment: .bottom) {
			if let copiedItemText {
				Text(.localized("Copied \(copiedItemText)"))
					.font(.caption.weight(.semibold))
					.foregroundStyle(.white)
					.padding(.horizontal, 14)
					.padding(.vertical, 8)
					.background(.black.opacity(0.8), in: Capsule())
					.padding(.bottom, 24)
					.transition(.opacity.combined(with: .move(edge: .bottom)))
			}
		}
	}

	private var entitlementsSection: some View {
		Section(.localized("Entitlements")) {
			if app.entitlementsList.isEmpty {
				Text(.localized("No Entitlements"))
					.foregroundStyle(.secondary)
			} else {
				ForEach(app.entitlementsList, id: \.key) { item in
					VStack(alignment: .leading, spacing: 4) {
						HStack {
							Text(item.key)
								.font(.caption.weight(.semibold))
								.foregroundStyle(.primary)
							Spacer()
							Button {
								UIPasteboard.general.string = "\(item.key): \(item.value)"
								_triggerCopyFeedback(label: item.key)
							} label: {
								Image(systemName: "doc.on.doc")
									.font(.caption2)
									.foregroundStyle(.secondary)
							}
							.buttonStyle(.plain)
						}

						Text(item.value)
							.font(.caption2.monospaced())
							.foregroundStyle(.secondary)
							.textSelection(.enabled)
					}
					.padding(.vertical, 2)
				}
			}
		}
	}

	@ViewBuilder
	private func _detailRow(label: String, value: String, isCopyable: Bool = false) -> some View {
		HStack(alignment: .top) {
			Text(label)
				.font(.subheadline)
				.foregroundStyle(.secondary)
				.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

			Spacer(minLength: 8)

			Text(value)
				.font(.subheadline)
				.foregroundStyle(.primary)
				.multilineTextAlignment(.trailing)
				.textSelection(.enabled)
				.frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)

			if isCopyable {
				Button {
					UIPasteboard.general.string = value
					_triggerCopyFeedback(label: label)
				} label: {
					Image(systemName: "doc.on.doc")
						.font(.caption2)
						.foregroundStyle(.secondary)
						.frame(width: 44, height: 44)
						.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				.accessibilityLabel(Text("Copy \(label)"))
			}
		}
		.padding(.vertical, 2)
	}

	private func _triggerCopyFeedback(label: String) {
		let generation = UUID()
		copyFeedbackGeneration = generation
		HapticManager.shared.impact()
		withAnimation(.easeInOut(duration: 0.2)) {
			copiedItemText = label
		}
		DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
			withAnimation(.easeInOut(duration: 0.2)) {
				if copyFeedbackGeneration == generation {
					copiedItemText = nil
				}
			}
		}
	}
}
