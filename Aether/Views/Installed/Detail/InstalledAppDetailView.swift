//
//  InstalledAppDetailView.swift
//  Aether
//

import SwiftUI
import IDeviceSwift

struct InstalledAppDetailView: View {
	@Environment(\.dismiss) private var dismiss
	let app: InstalledApp
	@ObservedObject var store: InstalledAppsStore

	@State private var isUninstallPresented = false
	@State private var isUninstalling = false
	@State private var uninstallErrorMessage: String?
	@State private var copiedItemText: String?

	var body: some View {
		ScrollViewReader { scrollProxy in
			List {
				Section {
					HStack {
						SettingsRowLabel(
							.localized("Signer"),
							systemImage: "signature",
							backgroundColor: .orange
						)
						Spacer(minLength: 8)
						Text(app.signerIdentity ?? .localized("Unavailable"))
							.font(.subheadline)
							.foregroundStyle(.secondary)
							.multilineTextAlignment(.trailing)
					}
				} header: {
					Text(.localized("Information"))
				}

				Section(.localized("Specifications")) {
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
										.font(.subheadline.monospaced())
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
				.id("informationSection")

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
			.listStyle(.insetGrouped)
			.navigationTitle(app.displayName)
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .principal) {
					HStack(spacing: 8) {
						InstalledAppIconView(
							bundleIdentifier: app.bundleIdentifier,
							cacheVersion: app.iconCacheVersion,
							loadsIcon: true,
							size: 26
						)
						Text(app.displayName)
							.font(.headline)
							.lineLimit(1)
					}
				}

				ToolbarItem(placement: .topBarTrailing) {
					Button(role: .destructive) {
						isUninstallPresented = true
					} label: {
						if isUninstalling {
							ProgressView()
								.controlSize(.small)
						} else {
							Image(systemName: "trash")
						}
					}
					.tint(.red)
					.disabled(isUninstalling)
					.accessibilityLabel(.localized("Uninstall"))
				}
			}
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
			.alert(.localized("Uninstall \(app.name)?"), isPresented: $isUninstallPresented) {
				Button(.localized("Uninstall"), role: .destructive) {
					Task { await _uninstallApp() }
				}
				Button(.localized("Cancel"), role: .cancel) {}
			} message: {
				Text(.localized("This will remove '\(app.name)' and all its stored data from your device."))
			}
			.alert(.localized("Couldn’t Uninstall"), isPresented: Binding(
				get: { uninstallErrorMessage != nil },
				set: { if !$0 { uninstallErrorMessage = nil } }
			)) {
				Button(.localized("OK"), role: .cancel) {}
			} message: {
				Text(uninstallErrorMessage ?? "")
			}
			#if DEBUG
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Aether.scrollDetailToBottom"))) { _ in
				withAnimation {
					scrollProxy.scrollTo("informationSection", anchor: .top)
				}
			}
			#endif
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
				}
				.buttonStyle(.plain)
			}
		}
		.padding(.vertical, 2)
	}

	private func _uninstallApp() async {
		isUninstalling = true
		defer { isUninstalling = false }

		do {
			try await store.delete(app: app)
			dismiss()
		} catch {
			uninstallErrorMessage = error.localizedDescription
		}
	}

	private func _triggerCopyFeedback(label: String) {
		HapticManager.shared.impact()
		withAnimation(.easeInOut(duration: 0.2)) {
			copiedItemText = label
		}
		DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
			withAnimation(.easeInOut(duration: 0.2)) {
				if copiedItemText == label {
					copiedItemText = nil
				}
			}
		}
	}
}
