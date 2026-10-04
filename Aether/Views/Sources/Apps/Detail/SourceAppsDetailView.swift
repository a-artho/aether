//
//  SourceAppsDetailView.swift
//  Aether
//
//  Created by samsam on 7/25/25.
//

import SwiftUI
import Combine
import AltSourceKit
import NimbleViews
import NukeUI
import UIKit

// MARK: - SourceAppsDetailView
struct SourceAppsDetailView: View {
	@ObservedObject var downloadManager = DownloadManager.shared
	@State private var _downloadProgress: Double = 0
	@State var cancellable: AnyCancellable? // Combine
	@State private var _isScreenshotPreviewPresented: Bool = false
	@State private var _selectedScreenshotIndex: Int = 0
	@State private var _appStoreDestination: AppStoreDestination?

	var currentDownload: Download? {
		guard let url = app.currentDownloadUrl else { return nil }
		return downloadManager.getDownload(
			from: url,
			sourceProvenance: SourceAppProvenance(sourceURL: sourceURL, repository: source, app: app)
		)
	}

	let sourceURL: URL?
	let source: ASRepository
	let app: ASRepository.App

	var body: some View {
		let appDescription = _cleanSourceText(app.localizedDescription)
		let releaseNotes = _cleanSourceText(app.currentAppVersion?.localizedDescription)

		ScrollView {
			VStack(alignment: .leading, spacing: 28) {
				_metadataStrip()

				if let screenshotURLs = app.screenshotURLs, !screenshotURLs.isEmpty {
					_detailSection(.localized("Screenshots")) {
						_screenshots(screenshotURLs: screenshotURLs)
					}
				}

				if let currentVersion = app.currentVersion,
				   !currentVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
				   let releaseNotes,
				   !SourceAppBodyText.matches(releaseNotes, appDescription) {

					_detailSection(.localized("What's New")) {
						VStack(alignment: .leading, spacing: 10) {
							AppVersionInfo(
								version: currentVersion,
								date: app.currentDate?.date,
								description: releaseNotes,
								textStyle: .subheadline
							)

							if let versions = app.versions, versions.count > 1 {
								NavigationLink(
									destination: VersionHistoryView(
										sourceURL: sourceURL,
										source: source,
										app: app,
										versions: versions
									)
									.navigationTitle(.localized("Version History"))
									.navigationBarTitleDisplayMode(.inline)
								) {
									HStack(spacing: 8) {
										Text(.localized("Version History"))
											.font(.subheadline.weight(.medium))

										Spacer()

										Image(systemName: "chevron.right")
											.font(.caption2.weight(.semibold))
											.foregroundStyle(.tertiary)
									}
									.foregroundStyle(Color.accentColor)
									.contentShape(Rectangle())
								}
								.buttonStyle(.plain)
								.padding(.top, 2)
							}
						}
					}
				}

				if let appDescription {
					_detailSection(
						.localized("Description"),
						trailing: {
							_appStoreLink()
						}
					) {
						ExpandableText(
							text: appDescription,
							lineLimit: 4,
							textStyle: .subheadline
						)
					}
				}

				_detailSection(.localized("Information")) {
					_informationRows()
				}

				if let appPermissions = app.appPermissions {
					_detailSection(.localized("Permissions")) {
						Group {
							if let entitlements = appPermissions.entitlements {
								NBTitleWithSubtitleView(
									title: .localized("Entitlements"),
									subtitle: SourceAppBodyText.replacingEmoji(in: entitlements.map(\.name).joined(separator: "\n"))
								)
							} else {
								Text(.localized("No Entitlements listed."))
									.font(.subheadline)
									.foregroundStyle(.secondary)
							}
							if let privacyItems = appPermissions.privacy {
								ForEach(privacyItems, id: \.self) { item in
									NBTitleWithSubtitleView(
										title: SourceAppBodyText.replacingEmoji(in: item.name),
										subtitle: SourceAppBodyText.replacingEmoji(in: item.usageDescription)
									)
								}
							} else {
								Text(.localized("No Privacy Permissions listed."))
									.font(.subheadline)
									.foregroundStyle(.secondary)
							}
						}
						.padding()
						.background(
							RoundedRectangle(cornerRadius: 18, style: .continuous)
								.fill(Color(.quaternarySystemFill))
						)
					}
				}
			}
			.padding(.horizontal, 20)
			.padding(.top, 10)
			.padding(.bottom, 44)
		}
		.background(Color(uiColor: .systemBackground).ignoresSafeArea())
		.navigationTitle(app.currentName)
		.navigationBarTitleDisplayMode(.inline)
		.toolbar {
			ToolbarItem(placement: .principal) {
				HStack(spacing: 8) {
					_navigationIcon
					Text(app.currentName)
						.font(.headline)
						.lineLimit(1)
				}
			}
			ToolbarItem(placement: .topBarTrailing) {
				DownloadButtonView(
					sourceURL: sourceURL,
					source: source,
					app: app,
					style: .navigation
				)
			}
		}
		.fullScreenCover(isPresented: $_isScreenshotPreviewPresented) {
			if let screenshotURLs = app.screenshotURLs {
				ScreenshotPreviewView(
					screenshotURLs: screenshotURLs,
					initialIndex: _selectedScreenshotIndex
				)
			}
		}
		.task(id: "\(app.id ?? "")|\(app.currentName)") {
			_appStoreDestination = await AppStoreLookup.shared.destination(
				bundleID: app.id,
				appName: app.currentName
			)
		}
	}

	@ViewBuilder
	private var _navigationIcon: some View {
		if let iconURL = app.iconURL {
			LazyImage(url: iconURL) { state in
				if let image = state.image {
					image.appIconStyle(size: 26, isCircle: false)
				} else {
					Image("App_Unknown").appIconStyle(size: 26, isCircle: false)
				}
			}
		} else {
			Image("App_Unknown").appIconStyle(size: 26, isCircle: false)
		}
	}

	private func _shareApp() {
		let sharedString = """
		\(app.currentName) - \(app.currentVersion ?? "0")
		\(app.currentDescription ?? .localized("An awesome application"))
		---
		\(source.website?.absoluteString ?? source.name ?? "")
		"""
		UIActivityViewController.show(activityItems: [sharedString])
	}

	private func _openAppStore(_ url: URL) {
		#if targetEnvironment(simulator)
		UIApplication.shared.open(url, options: [:], completionHandler: nil)
		#else
		let appStoreURL: URL
		if var components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.host == "apps.apple.com" {
			components.scheme = "itms-apps"
			appStoreURL = components.url ?? url
		} else {
			appStoreURL = url
		}

		UIApplication.shared.open(appStoreURL, options: [:]) { didOpen in
			if !didOpen, appStoreURL != url {
				UIApplication.shared.open(url, options: [:], completionHandler: nil)
			}
		}
		#endif
	}
}

// MARK: - SourceAppsDetailView (Extension): Builders
extension SourceAppsDetailView {

	// MARK: Boilerplate cleanup

	private static let _genericSourcePlaceholder =
		"No tweak information supplied by the source."

	private func _cleanSourceText(_ rawValue: String?) -> String? {
		guard let rawValue else { return nil }

		var text = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)

		guard !text.isEmpty else {
			return nil
		}

		if text.localizedCaseInsensitiveCompare(Self._genericSourcePlaceholder) == .orderedSame {
			return nil
		}

		if text.hasPrefix(Self._genericSourcePlaceholder) {
			text = String(text.dropFirst(Self._genericSourcePlaceholder.count))
				.trimmingCharacters(in: .whitespacesAndNewlines)

			return SourceAppBodyText.body(in: text)
		}

		return SourceAppBodyText.body(in: text)
	}

	// MARK: Section helpers (local to this screen — do not use NBSection here)

	@ViewBuilder
	private func _detailSection<Content: View>(
		_ title: String,
		@ViewBuilder content: () -> Content
	) -> some View {
		VStack(alignment: .leading, spacing: 10) {
			Text(title)
				.font(.title3.weight(.semibold))
				.foregroundStyle(.primary)

			content()
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	@ViewBuilder
	private func _detailSection<Trailing: View, Content: View>(
		_ title: String,
		@ViewBuilder trailing: () -> Trailing,
		@ViewBuilder content: () -> Content
	) -> some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack(alignment: .firstTextBaseline, spacing: 12) {
				Text(title)
					.font(.title3.weight(.semibold))
					.foregroundStyle(.primary)

				Spacer(minLength: 8)

				trailing()
			}

			content()
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	// MARK: Metadata strip

	private struct DetailMetric: Identifiable {
		let id: String
		let label: String
		let value: String
	}

	private var _metadataMetrics: [DetailMetric] {
		var metrics: [DetailMetric] = []

		if let version = app.currentVersion,
		   !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			metrics.append(
				DetailMetric(
					id: "version",
					label: .localized("Version").uppercased(),
					value: version
				)
			)
		}

		if let size = app.size {
			metrics.append(
				DetailMetric(
					id: "size",
					label: .localized("Size").uppercased(),
					value: size.formattedByteCount
				)
			)
		}

		if let date = app.currentDate?.date {
			metrics.append(
				DetailMetric(
					id: "updated",
					label: .localized("Updated").uppercased(),
					value: date.formatted(.relative(presentation: .named))
				)
			)
		}

		return metrics
	}

	@ViewBuilder
	private func _metadataStrip() -> some View {
		let metrics = _metadataMetrics

		if !metrics.isEmpty {
			HStack(spacing: 0) {
				ForEach(metrics.indices, id: \.self) { index in
					let metric = metrics[index]

					if index > 0 {
						Divider()
							.frame(height: 32)
							.padding(.horizontal, 12)
					}

					VStack(alignment: .leading, spacing: 3) {
						Text(metric.label)
							.font(.caption2.weight(.medium))
							.foregroundStyle(.secondary)
							.lineLimit(1)

						Text(SourceAppBodyText.replacingEmoji(in: metric.value))
							.font(.subheadline.weight(.semibold))
							.foregroundStyle(.primary)
							.lineLimit(1)
							.minimumScaleFactor(0.8)
					}
					.frame(maxWidth: .infinity, alignment: .leading)
				}
			}
			.padding(.vertical, 4)
		}
	}

	// MARK: App Store link

	@ViewBuilder
	private func _appStoreLink() -> some View {
		if let destination = _appStoreDestination {
			Button {
				_openAppStore(destination.url)
			} label: {
				HStack(spacing: 4) {
					Text("App Store")
						.underline()
						.foregroundStyle(.secondary)

					Image(systemName: "arrow.up.right")
						.font(.caption2.weight(.semibold))
						.foregroundStyle(Color.accentColor)
				}
				.font(.subheadline)
			}
			.buttonStyle(.plain)
		}
	}

	// MARK: Information rows

	@ViewBuilder
	private func _informationRows() -> some View {
		let rows: [(title: String, value: String)] = [
			source.name.flatMap {
				(title: .localized("Source"), value: $0)
			},

			app.developer.flatMap {
				(title: .localized("Developer"), value: $0)
			},

			app.category.flatMap {
				(title: .localized("Category"), value: $0.capitalized)
			},

			app.id.flatMap {
				(title: .localized("Identifier"), value: $0)
			}
		]
		.compactMap { $0 }

		VStack(spacing: 0) {
			ForEach(rows.indices, id: \.self) { index in
				let row = rows[index]

				_infoRow(
					title: row.title,
					value: row.value,
					isLast: index == rows.count - 1
				)
			}
		}
		.background {
			RoundedRectangle(cornerRadius: 16, style: .continuous)
				.fill(Color(uiColor: .secondarySystemGroupedBackground))
		}
		.clipShape(
			RoundedRectangle(cornerRadius: 16, style: .continuous)
		)
	}

	@ViewBuilder
	private func _infoRow(
		title: String,
		value: String,
		isLast: Bool
	) -> some View {
		HStack(alignment: .firstTextBaseline, spacing: 16) {
			Text(title)
				.font(.subheadline)
				.foregroundStyle(.secondary)
				.layoutPriority(1)

			Spacer(minLength: 12)

			Text(SourceAppBodyText.replacingEmoji(in: value))
				.font(.subheadline)
				.foregroundStyle(.primary)
				.multilineTextAlignment(.trailing)
				.lineLimit(2)
				.fixedSize(horizontal: false, vertical: true)
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 11)

		if !isLast {
			Divider()
				.padding(.leading, 14)
		}
	}

	// MARK: Screenshots

	@ViewBuilder
	private func _screenshots(screenshotURLs: [URL]) -> some View {
		ScrollView(.horizontal, showsIndicators: false) {
			HStack(spacing: 12) {
				ForEach(screenshotURLs.indices, id: \.self) { index in
					let url = screenshotURLs[index]
					LazyImage(url: url) { state in
						if let image = state.image {
							image
								.resizable()
								.aspectRatio(contentMode: .fit)
								.frame(maxWidth: .infinity, maxHeight: 350)
								.clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
								.overlay {
									RoundedRectangle(cornerRadius: 18, style: .continuous)
										.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
								}
								.onTapGesture {
									_selectedScreenshotIndex = index
									_isScreenshotPreviewPresented = true
								}
						}
					}
				}
			}
			.padding(.horizontal)
			.compatScrollTargetLayout()
		}
		.compatScrollTargetBehavior()
		.padding(.horizontal, -20)
	}
}
