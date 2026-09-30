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

	@State private var isLaunching = false
	@State private var launchErrorMessage: String?
	@State private var isTerminating = false
	@State private var terminateResultMessage: String?
	@State private var isUninstallPresented = false
	@State private var isUninstalling = false
	@State private var uninstallErrorMessage: String?
	@State private var isFilesPresented = false

	var body: some View {
		ScrollViewReader { scrollProxy in
			List {
			Section {
				_appControlsGrid
					.listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
					.listRowBackground(Color.clear)
					.listRowSeparator(.hidden)
			}
			.listSectionSeparator(.hidden)

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

				NavigationLink {
					InstalledAppSpecificationsView(app: app)
				} label: {
					SettingsRowLabel(
						.localized("Specifications"),
						systemImage: "info.circle.fill",
						backgroundColor: .blue
					)
				}

				NavigationLink {
					InstalledAppEntitlementsView(app: app)
				} label: {
					HStack {
						SettingsRowLabel(
							.localized("Entitlements"),
							systemImage: "lock.shield.fill",
							backgroundColor: .purple
						)
						Spacer()
						Text("\(app.entitlementsList.count)")
							.foregroundStyle(.secondary)
					}
				}
			}
			.id("informationSection")
		}
		.listStyle(.insetGrouped)
		.background(
			NavigationLink(
				destination: SandboxBrowserView(app: app),
				isActive: $isFilesPresented
			) {
				EmptyView()
			}
			.hidden()
		)
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
		}
		.alert(.localized("Launch Failed"), isPresented: Binding(
			get: { launchErrorMessage != nil },
			set: { if !$0 { launchErrorMessage = nil } }
		)) {
			Button(.localized("OK"), role: .cancel) {}
		} message: {
			if let msg = launchErrorMessage {
				Text(msg)
			}
		}
		.alert(.localized("Process Control"), isPresented: Binding(
			get: { terminateResultMessage != nil },
			set: { if !$0 { terminateResultMessage = nil } }
		)) {
			Button(.localized("OK"), role: .cancel) {}
		} message: {
			if let msg = terminateResultMessage {
				Text(msg)
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
		#if DEBUG
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Aether.scrollDetailToBottom"))) { _ in
			withAnimation {
				scrollProxy.scrollTo("informationSection", anchor: .top)
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Aether.openAppSandbox"))) { _ in
			isFilesPresented = true
		}
		#endif
		}
	}

	// MARK: - Views

	private var _appControlsGrid: some View {
		VStack(spacing: 10) {
			HStack(spacing: 12) {
				_appAccessoryTile(
					title: .localized("Launch"),
					subtitle: isLaunching ? .localized("Launching...") : .localized("Open App"),
					systemImage: "play.fill",
					isActive: true,
					activeColor: .blue,
					isDisabled: isLaunching,
					isLoading: isLaunching,
					action: {
						Task { await _launchApp() }
					}
				)

				_appAccessoryTile(
					title: .localized("Files"),
					subtitle: .localized("App Sandbox"),
					systemImage: "folder.fill",
					isActive: true,
					activeColor: .cyan,
					action: {
						isFilesPresented = true
					}
				)
			}

			HStack(spacing: 12) {
				_appAccessoryTile(
					title: .localized("Kill"),
					subtitle: isTerminating ? .localized("Stopping...") : .localized("Force Quit"),
					systemImage: "xmark.octagon.fill",
					isActive: true,
					activeColor: .orange,
					isDisabled: isTerminating,
					isLoading: isTerminating,
					action: {
						Task { await _terminateApp() }
					}
				)

				_appAccessoryTile(
					title: .localized("Uninstall"),
					subtitle: .localized("Remove App"),
					systemImage: "trash.fill",
					isActive: true,
					activeColor: .red,
					isDisabled: isUninstalling,
					isLoading: isUninstalling,
					action: {
						isUninstallPresented = true
					}
				)
			}
		}
	}

	@ViewBuilder
	private func _appAccessoryTile(
		title: String,
		subtitle: String,
		systemImage: String,
		isActive: Bool,
		activeColor: Color,
		isDisabled: Bool = false,
		isLoading: Bool = false,
		action: @escaping () -> Void
	) -> some View {
		Button(action: action) {
			HStack(spacing: 8) {
				if isLoading {
					ProgressView()
						.controlSize(.small)
						.frame(width: 24, height: 24)
				} else {
					Image(systemName: systemImage)
						.font(.system(size: 17, weight: .semibold))
						.foregroundStyle(isActive ? activeColor : Color.secondary.opacity(isDisabled ? 0.55 : 1))
						.frame(width: 24, height: 24)
				}

				VStack(alignment: .leading, spacing: 2) {
					Text(title)
						.font(.subheadline.weight(.semibold))
						.foregroundStyle(.primary)
						.lineLimit(1)

					Text(subtitle)
						.font(.caption2.weight(.medium))
						.foregroundStyle(.secondary)
						.lineLimit(1)
						.minimumScaleFactor(0.8)
				}

				Spacer(minLength: 0)
			}
			.padding(.horizontal, 10)
			.padding(.vertical, 8)
			.frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
			.background {
				RoundedRectangle(cornerRadius: 15, style: .continuous)
					.fill(Color(uiColor: .secondarySystemGroupedBackground))
			}
		}
		.buttonStyle(_TileButtonStyle {
			HapticManager.shared.impact()
		})
		.disabled(isDisabled)
		.opacity(isDisabled ? 0.6 : 1.0)
	}

	// MARK: - Actions

	private func _launchApp() async {
		isLaunching = true
		launchErrorMessage = nil
		defer { isLaunching = false }

		do {
			try await AppLifecycleService.launchApp(
				bundleIdentifier: app.bundleIdentifier,
				urlSchemes: app.registeredUrlSchemes
			)
		} catch {
			launchErrorMessage = error.localizedDescription
		}
	}

	private func _terminateApp() async {
		isTerminating = true
		terminateResultMessage = nil
		defer { isTerminating = false }

		do {
			let killed = try await AppLifecycleService.terminateApp(
				bundleIdentifier: app.bundleIdentifier,
				executableName: app.executableName
			)
			terminateResultMessage = killed
				? .localized("Successfully terminated running process.")
				: .localized("No running process was found for this app.")
		} catch {
			terminateResultMessage = error.localizedDescription
		}
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
}

private struct InstalledAppSpecificationsView: View {
	let app: InstalledApp
	@State private var copiedItemText: String?

	var body: some View {
		List {
			Section {
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
					.padding(.vertical, 4)
				}
			}
		}
		.listStyle(.insetGrouped)
		.navigationTitle(.localized("Specifications"))
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

	@ViewBuilder
	private func _detailRow(label: String, value: String, isCopyable: Bool = false) -> some View {
		HStack(alignment: .top) {
			Text(label)
				.font(.subheadline)
				.foregroundStyle(.secondary)
				.frame(width: 110, alignment: .leading)

			Spacer(minLength: 8)

			Text(value)
				.font(.subheadline)
				.foregroundStyle(.primary)
				.multilineTextAlignment(.trailing)
				.textSelection(.enabled)

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

private struct InstalledAppEntitlementsView: View {
	let app: InstalledApp
	@State private var searchText = ""
	@State private var copiedItemText: String?

	private var filteredEntitlements: [(key: String, value: String)] {
		guard !searchText.isEmpty else { return app.entitlementsList }
		return app.entitlementsList.filter {
			$0.key.localizedCaseInsensitiveContains(searchText)
				|| $0.value.localizedCaseInsensitiveContains(searchText)
		}
	}

	var body: some View {
		Group {
			if app.entitlementsList.isEmpty {
				TabPlaceholderView(
					title: .localized("No Entitlements"),
					description: "",
					systemImage: "lock.slash"
				)
			} else {
				List {
					ForEach(filteredEntitlements, id: \.key) { item in
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
		.navigationTitle(.localized("Entitlements"))
		.navigationBarTitleDisplayMode(.inline)
		.searchable(text: $searchText, prompt: .localized("Search Entitlements"))
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

private struct _TileButtonStyle: ButtonStyle {
	let onPress: () -> Void

	func makeBody(configuration: Configuration) -> some View {
		_TileButtonStyleBody(configuration: configuration, onPress: onPress)
	}
}

private struct _TileButtonStyleBody: View {
	let configuration: _TileButtonStyle.Configuration
	let onPress: () -> Void
	@State private var keepsPressedAppearance = false
	@State private var releaseTask: Task<Void, Never>?

	private var isPressed: Bool {
		configuration.isPressed || keepsPressedAppearance
	}

	var body: some View {
		configuration.label
			.scaleEffect(isPressed ? 0.965 : 1.0)
			.opacity(isPressed ? 0.84 : 1.0)
			.overlay {
				RoundedRectangle(cornerRadius: 15, style: .continuous)
					.fill(.black.opacity(isPressed ? 0.08 : 0))
			}
			.animation(.spring(response: 0.2, dampingFraction: 0.82), value: isPressed)
			.onChange(of: configuration.isPressed) { pressed in
				if pressed {
					releaseTask?.cancel()
					keepsPressedAppearance = true
					onPress()
				} else {
					releaseTask?.cancel()
					releaseTask = Task { @MainActor in
						try? await Task.sleep(for: .milliseconds(110))
						keepsPressedAppearance = false
					}
				}
			}
	}
}
