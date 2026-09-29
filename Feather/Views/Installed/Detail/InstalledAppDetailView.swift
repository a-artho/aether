//
//  InstalledAppDetailView.swift
//  Feather
//

import SwiftUI
import CoreData
import IDeviceSwift
import NimbleViews

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
	@State private var hasCopiedBundleId = false
	@State private var copiedItemText: String?
	@State private var entitlementsSearchText = ""
	@State private var isFilesPresented = false
	@State private var signingApp: AnyApp?
	@State private var feedbackGenerator = UIImpactFeedbackGenerator(style: .light)

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

			// MARK: - Feature 2: Signing & Certificate
			Section {
				_signingStatusCard
				if let profile = app.profileInfo {
					_detailRow(label: .localized("Profile"), value: profile.name ?? profile.profileType)
					if let team = profile.teamName {
						_detailRow(label: .localized("Team Name"), value: team)
					}
					if let teamId = profile.entitlementTeamIdentifier ?? profile.teamIdentifiers.first {
						_detailRow(label: .localized("Team ID"), value: teamId, isCopyable: true)
					}
					_detailRow(label: .localized("Expires"), value: profile.expirationDate.formatted(date: .abbreviated, time: .shortened))
					if let creation = profile.creationDate {
						_detailRow(label: .localized("Created"), value: creation.formatted(date: .abbreviated, time: .shortened))
					}
					if let uuid = profile.uuid {
						_detailRow(label: .localized("Profile UUID"), value: uuid, isCopyable: true)
					}
				} else if let signer = app.signerIdentity {
					_detailRow(label: .localized("Signer"), value: signer)
				}
			} header: {
				Label(.localized("Certificate & Signing"), systemImage: "signature")
			}

			// Invisible navigation trigger for Files widget
			ZStack {
				NavigationLink(
					destination: SandboxBrowserView(app: app),
					isActive: $isFilesPresented
				) {
					EmptyView()
				}
				.hidden()
			}
			.listRowInsets(EdgeInsets())
			.listRowBackground(Color.clear)
			.listRowSeparator(.hidden)

			// MARK: - Feature 5: App Specifications
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
				if let exe = app.executableName {
					_detailRow(label: .localized("Executable"), value: exe)
				}
				if let minOS = app.minimumOSVersion {
					_detailRow(label: .localized("Minimum iOS"), value: "iOS \(minOS)+")
				}
				_detailRow(label: .localized("Target Devices"), value: app.deviceFamilies.joined(separator: ", "))
				if let sdk = app.sdkName {
					_detailRow(label: .localized("SDK"), value: sdk)
				}
				if let xcode = app.xcodeBuild {
					_detailRow(label: .localized("Xcode Build"), value: xcode)
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
									HStack(spacing: 4) {
										Image(systemName: "arrow.up.right")
										Text(.localized("Open"))
									}
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
			} header: {
				Label(.localized("Specifications"), systemImage: "info.circle")
			}

			// MARK: - Feature 5: Entitlements Inspector
			if !app.entitlementsList.isEmpty {
				Section {
					ForEach(_filteredEntitlements, id: \.key) { item in
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
				} header: {
					HStack {
						Label(.localized("Entitlements"), systemImage: "lock.shield")
						Spacer()
						Text("\(app.entitlementsList.count)")
							.font(.caption2.weight(.semibold))
							.foregroundStyle(.secondary)
					}
				}
			}

			Section {
				Color.clear
					.frame(height: 70)
					.listRowBackground(Color.clear)
					.listRowSeparator(.hidden)
			}
			.id("bottomSpacer")
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
		.overlay(alignment: .bottom) {
			if let copiedText = copiedItemText {
				Text(.localized("Copied \(copiedText)"))
					.font(.caption.weight(.semibold))
					.foregroundStyle(.white)
					.padding(.horizontal, 14)
					.padding(.vertical, 8)
					.background(.black.opacity(0.8), in: Capsule())
					.padding(.bottom, 24)
					.transition(.opacity.combined(with: .move(edge: .bottom)))
			}
		}
		.fullScreenCover(item: $signingApp) { app in
			SigningView(app: app.base)
		}
		#if DEBUG
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Feather.scrollDetailToBottom"))) { _ in
			withAnimation {
				scrollProxy.scrollTo("bottomSpacer", anchor: .bottom)
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Feather.openAppSandbox"))) { _ in
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
		.onAppear {
			feedbackGenerator.prepare()
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
			feedbackGenerator.impactOccurred()
			feedbackGenerator.prepare()
		})
		.disabled(isDisabled)
		.opacity(isDisabled ? 0.6 : 1.0)
	}

	private var _signingStatusCard: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack(alignment: .center) {
				VStack(alignment: .leading, spacing: 2) {
					Text(app.profileInfo?.profileType ?? .localized("Sideloaded Certificate"))
						.font(.subheadline.weight(.semibold))
						.foregroundStyle(.primary)

					Text(app.profileInfo?.timeRemainingFormatted ?? .localized("Expiration tracked via pairing"))
						.font(.caption)
						.foregroundStyle(app.profileInfo.map { _expirationColor(for: $0) } ?? .secondary)
				}

				Spacer(minLength: 8)

				Button {
					_triggerResign()
				} label: {
					HStack(spacing: 5) {
						Image(systemName: "signature")
							.font(.system(size: 13, weight: .semibold))
						Text(.localized("Resign"))
							.font(.subheadline.weight(.semibold))
					}
					.foregroundStyle(.white)
					.padding(.horizontal, 14)
					.padding(.vertical, 7)
					.background(Color.accentColor, in: Capsule())
				}
				.buttonStyle(.plain)
			}

			if let profile = app.profileInfo {
				let totalDays: Double = profile.profileType.contains("7 Days") ? 7.0 : 365.0
				let progress = min(1.0, max(0.0, Double(profile.daysRemaining) / totalDays))
				ProgressView(value: progress)
					.tint(_expirationColor(for: profile))
			}
		}
		.padding(.vertical, 4)
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

	private var _filteredEntitlements: [(key: String, value: String)] {
		if entitlementsSearchText.isEmpty {
			return app.entitlementsList
		}
		return app.entitlementsList.filter {
			$0.key.localizedCaseInsensitiveContains(entitlementsSearchText)
				|| $0.value.localizedCaseInsensitiveContains(entitlementsSearchText)
		}
	}

	private func _expirationColor(for profile: ProvisioningProfileInfo) -> Color {
		if profile.isExpired {
			return .red
		} else if profile.daysRemaining <= 2 {
			return .orange
		} else {
			return .green
		}
	}

	private func _triggerCopyFeedback(label: String) {
		UIImpactFeedbackGenerator(style: .light).impactOccurred()
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

	private func _triggerResign() {
		feedbackGenerator.impactOccurred()
		feedbackGenerator.prepare()

		let context = Storage.shared.context
		let signedRequest: NSFetchRequest<Signed> = Signed.fetchRequest()
		signedRequest.predicate = NSPredicate(format: "identifier == %@", app.bundleIdentifier)
		signedRequest.fetchLimit = 1

		if let matchingSigned = try? context.fetch(signedRequest).first {
			signingApp = AnyApp(base: matchingSigned)
			return
		}

		let importedRequest: NSFetchRequest<Imported> = Imported.fetchRequest()
		importedRequest.predicate = NSPredicate(format: "identifier == %@", app.bundleIdentifier)
		importedRequest.fetchLimit = 1

		if let matchingImported = try? context.fetch(importedRequest).first {
			signingApp = AnyApp(base: matchingImported)
			return
		}

		let sideloaded = SideloadedAppPresentable(
			name: app.name,
			version: app.version,
			identifier: app.bundleIdentifier,
			date: app.profileInfo?.creationDate ?? Date(),
			icon: nil,
			uuid: app.profileInfo?.uuid ?? app.bundleIdentifier,
			source: app.bundlePath.flatMap { URL(fileURLWithPath: $0) },
			isSigned: true
		)
		signingApp = AnyApp(base: sideloaded)
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

private struct SideloadedAppPresentable: AppInfoPresentable {
	let name: String?
	let version: String?
	let identifier: String?
	let date: Date?
	let icon: String?
	let uuid: String?
	let source: URL?
	let isSigned: Bool
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
