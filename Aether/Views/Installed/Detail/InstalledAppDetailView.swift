//
//  InstalledAppDetailView.swift
//  Aether
//

import SwiftUI
import IDeviceSwift
import NimbleViews

struct InstalledAppDetailView: View {
	@AppStorage("Aether.controlsInHeader") private var controlsInHeader = false
	@Environment(\.dismiss) private var dismiss
	let app: InstalledApp
	@ObservedObject var store: InstalledAppsStore
	@ObservedObject private var sourcesViewModel = SourcesViewModel.shared
	@FetchRequest(sortDescriptors: []) private var sources: FetchedResults<AltSource>
	@State private var updates: [InstalledAppUpdateCandidate] = []
	@State private var selectedUpdate: InstalledAppUpdateCandidate?
	@State private var selectedInformationPage: InstalledAppInformationView.Page?
	@State private var hasCheckedUpdates = false

	@State private var isUninstallPresented = false
	@State private var isUninstalling = false
	@State private var uninstallErrorMessage: String?

	var body: some View {
		ScrollViewReader { scrollProxy in
			List {
				updatesSection.id("updatesSection")
			}
			.listStyle(.plain)
			.navigationTitle(app.displayName)
			.navigationBarTitleDisplayMode(.inline)
			.navigationDestination(isPresented: Binding(
				get: { selectedUpdate != nil },
				set: { if !$0 { selectedUpdate = nil } }
			)) {
				if let update = selectedUpdate {
					SourceAppsDetailView(sourceURL: update.sourceURL, source: update.repository, app: update.app)
				}
			}
			.sheet(item: $selectedInformationPage) { page in
				NBNavigationView(page.title, displayMode: .inline) {
					InstalledAppInformationView(app: app, page: page)
						.toolbar {
							ToolbarItem(placement: .topBarTrailing) {
								Button(.localized("Close"), systemImage: "xmark") {
									selectedInformationPage = nil
								}
								.tint(.primary)
							}
						}
				}
			}

			.task(id: updateRequest) {
				await sourcesViewModel.ensureSourcesLoaded(Array(sources))
				do {
					let matches = try await InstalledAppUpdateCatalog.shared.updates(
						for: app.bundleIdentifier, installedVersion: installedVersion, contexts: sourceContexts)
					try Task.checkCancellation()
					updates = matches
					hasCheckedUpdates = true
				} catch is CancellationError {
					// A newer catalog or installed version superseded this lookup.
				} catch {
					updates = []
					hasCheckedUpdates = true
				}
			}
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

				ToolbarItemGroup(placement: .topBarTrailing) {
					if controlsInHeader { informationHeaderButton(.specifications, systemImage: "info.circle") }
					Button {
						isUninstallPresented = true
					} label: {
						if isUninstalling {
							ProgressView()
								.controlSize(.small)
						} else {
							Image(systemName: "trash")
						}
					}
					.tint(.primary)
					.disabled(isUninstalling)
					.accessibilityLabel(.localized("Uninstall"))
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
					scrollProxy.scrollTo("updatesSection", anchor: .top)
				}
			}
			#endif
		}
		.modifier(DeviceControlsBar(controls: informationControls, isEnabled: !controlsInHeader))
	}

	@ViewBuilder
	private var updatesSection: some View {
		if hasCheckedUpdates && !updates.isEmpty {
			NBSection(.localized("Updates"), trailing: { updateRefreshStatus }) {
				ForEach(InstalledAppUpdateCandidate.groupedByDate(updates)) { group in
					SourceAppDateChip(title: updateDateTitle(group.date))
						.padding(.vertical, 4)
						.listRowSeparator(.hidden)
						.listRowBackground(Color.clear)
					ForEach(group.updates) { update in
						SourceAppsCellView(sourceURL: update.sourceURL, source: update.repository, app: update.app,
							showSourceBadge: true, onSelect: { selectedUpdate = update })
							.accessibilityHint(update.repository.name ?? update.sourceURL.host ?? "")
					}
				}
			}
		} else {
			NBSection(.localized("Updates"), trailing: { updateRefreshStatus }) {
				if !hasCheckedUpdates {
					HStack(spacing: 10) {
						ProgressView()
						Text(.localized("Checking for Updates…"))
							.font(.subheadline)
							.foregroundStyle(.secondary)
					}
					.frame(maxWidth: .infinity, minHeight: 60)
					.listRowSeparator(.hidden)
				} else {
					TabPlaceholderView(
						title: hasUnavailableCatalogs ? .localized("Updates Unavailable") : .localized("No Updates Available"),
						description: updatePlaceholderDescription,
						systemImage: hasUnavailableCatalogs ? "exclamationmark.arrow.triangle.2.circlepath" : "arrow.triangle.2.circlepath"
					)
					.frame(maxWidth: .infinity, minHeight: 260, alignment: .center)
					.listRowSeparator(.hidden)
				}
			}
		}
	}

	private var updateRefreshStatus: some View {
		SourceRefreshStatusView(
			lastUpdated: sourcesViewModel.lastUpdated,
			isRefreshing: !sourcesViewModel.isFinished,
			hasFailures: !sourcesViewModel.refreshErrors.isEmpty
		)
	}

	private func updateDateTitle(_ date: Date?) -> String {
		guard let date else { return .localized("Unknown Date") }
		let calendar = Calendar.current
		if calendar.isDateInToday(date) { return .localized("Today") }
		if calendar.isDateInYesterday(date) { return .localized("Yesterday") }
		let formatter = DateFormatter()
		formatter.locale = Locale.current
		formatter.dateFormat = "MMM d, yyyy"
		return formatter.string(from: date)
	}

	private func informationHeaderButton(_ page: InstalledAppInformationView.Page, systemImage: String) -> some View {
		Button {
			HapticManager.shared.impact()
			selectedInformationPage = page
		} label: {
			Image(systemName: systemImage).foregroundStyle(.secondary)
		}
		.accessibilityLabel(page.title)
	}

	private var informationControls: some View {
		DeviceAccessoryTileGroup {
			DeviceAccessoryTile(title: .localized("Info"), subtitle: .localized("App details"), systemImage: "info.circle") {
				selectedInformationPage = .specifications
			}
			DeviceAccessoryTile(title: .localized("Entitlements"), subtitle: .localized("Permissions"), systemImage: "key.horizontal") {
				selectedInformationPage = .entitlements
			}
		}
	}

	private var hasUnavailableCatalogs: Bool {
		sources.contains { sourcesViewModel.repository(for: $0) == nil }
	}

	private var updatePlaceholderDescription: String {
		if hasUnavailableCatalogs {
			return .localized("Some sources couldn’t be loaded. Refresh Sources to check again.")
		}
		if sources.isEmpty {
			return .localized("Add sources to check for newer versions of this app.")
		}
		if installedVersion?.isEmpty != false {
			return .localized("This app’s version is unavailable, so updates couldn’t be compared.")
		}
		return .localized("No newer versions were found in your added sources.")
	}

	private var installedVersion: String? {
		store.apps.first(where: { $0.bundleIdentifier == app.bundleIdentifier })?.version ?? app.version
	}

	private var sourceContexts: [SourceAppCatalogContext] {
		sources.compactMap { source in
			guard let repository = sourcesViewModel.repository(for: source) else { return nil }
			return SourceAppCatalogContext(sourceObjectURI: source.objectID.uriRepresentation().absoluteString,
				sourceURL: source.sourceURL, repository: repository, revision: sourcesViewModel.revision(for: source))
		}
	}

	private var updateRequest: [String] {
		[app.bundleIdentifier, installedVersion ?? "", String(sourcesViewModel.catalogRevision)] + sources.flatMap {
			[$0.objectID.uriRepresentation().absoluteString, $0.sourceURL?.absoluteString ?? ""]
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

private struct InstalledAppInformationView: View {
	enum Page: String, Identifiable {
		case specifications, entitlements

		var id: String { rawValue }

		var title: String {
			switch self {
			case .specifications: .localized("Info")
			case .entitlements: .localized("Entitlements")
			}
		}
	}

	let app: InstalledApp
	let page: Page
	@State private var copiedItemText: String?

	var body: some View {
		List {
			if page == .specifications {
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
			}
			entitlementsSection
		}
		.listStyle(.insetGrouped)
		.navigationTitle(page.title)
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
