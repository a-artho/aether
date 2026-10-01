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
		downloadManager.getDownload(by: app.currentUniqueId)
	}
	
	let sourceURL: URL?
	let source: ASRepository
	let app: ASRepository.App
	
	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 24) {
				_metadataTiles()

				if let screenshotURLs = app.screenshotURLs, !screenshotURLs.isEmpty {
					NBSection(.localized("Screenshots")) {
						_screenshots(screenshotURLs: screenshotURLs)
					}
				}

				if
					let currentVer = app.currentVersion,
					let whatsNewDesc = app.currentAppVersion?.localizedDescription
				{
					NBSection(.localized("What's New")) {
						VStack(alignment: .leading, spacing: 8) {
							AppVersionInfo(
								version: currentVer,
								date: app.currentDate?.date,
								description: whatsNewDesc
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
									HStack {
										Text(.localized("Version History"))
											.font(.subheadline.weight(.medium))
											.foregroundStyle(Color.accentColor)
										Spacer()
										Image(systemName: "chevron.right")
											.font(.caption2.weight(.semibold))
											.foregroundStyle(Color.secondary.opacity(0.4))
									}
									.padding(.top, 4)
								}
							}
						}
					}
				}

				if let appDesc = app.localizedDescription, !appDesc.isEmpty {
					NBSection(.localized("Description"), trailing: {
						_appStoreLink()
					}) {
						ExpandableText(text: appDesc, lineLimit: 4)
							.lineSpacing(3)
					}
				} else if _appStoreDestination != nil {
					NBSection(.localized("Description"), trailing: {
						_appStoreLink()
					}) {
						EmptyView()
					}
				}

				NBSection(.localized("Information")) {
					_informationRows()
				}

				if let appPermissions = app.appPermissions {
					NBSection(.localized("Permissions")) {
						Group {
							if let entitlements = appPermissions.entitlements {
								NBTitleWithSubtitleView(
									title: .localized("Entitlements"),
									subtitle: entitlements.map(\.name).joined(separator: "\n")
								)
							} else {
								Text(.localized("No Entitlements listed."))
									.font(.subheadline)
									.foregroundStyle(.secondary)
							}
							if let privacyItems = appPermissions.privacy {
								ForEach(privacyItems, id: \.self) { item in
									NBTitleWithSubtitleView(
										title: item.name,
										subtitle: item.usageDescription
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
			.padding(.horizontal, 16)
			.padding(.top, 8)
			.padding(.bottom, 36)
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
	@ViewBuilder
	private func _metadataTiles() -> some View {
		let version = app.currentVersion.flatMap { $0.isEmpty ? nil : $0 } ?? "—"
		let size = app.size?.formattedByteCount ?? "—"

		HStack(spacing: 12) {
			_metadataTile(
				title: .localized("Version"),
				subtitle: version,
				systemImage: "tag"
			)

			_metadataTile(
				title: .localized("Size"),
				subtitle: size,
				systemImage: "internaldrive"
			)
		}
	}

	private func _metadataTile(
		title: String,
		subtitle: String,
		systemImage: String
	) -> some View {
		HStack(spacing: 8) {
			Image(systemName: systemImage)
				.font(.system(size: 17, weight: .semibold))
				.foregroundStyle(.secondary)
				.frame(width: 24, height: 24)

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

	@ViewBuilder
	private func _appStoreLink() -> some View {
		if let destination = _appStoreDestination {
			Button {
				_openAppStore(destination.url)
			} label: {
				HStack(spacing: 4) {
					Image("AppStore")
						.renderingMode(.template)
						.resizable()
						.scaledToFit()
						.frame(width: 12, height: 12)
						.foregroundStyle(.secondary)

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

	@ViewBuilder
	private func _informationRows() -> some View {
		let rows: [(title: String, value: String)] = [
			source.name.flatMap { (title: .localized("Source"), value: $0) },
			app.developer.flatMap { (title: .localized("Developer"), value: $0) },
			app.size.flatMap { (title: .localized("Size"), value: $0.formattedByteCount) },
			app.category.flatMap { (title: .localized("Category"), value: $0.capitalized) },
			app.currentVersion.flatMap { (title: .localized("Version"), value: $0) },
			(app.currentDate?.date).flatMap { (title: .localized("Updated"), value: DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .none)) },
			app.id.flatMap { (title: .localized("Identifier"), value: $0) }
		].compactMap { $0 }

		VStack(spacing: 8) {
			ForEach(rows.indices, id: \.self) { index in
				let row = rows[index]
				_infoRow(title: row.title, value: row.value, isLast: index == rows.count - 1)
			}
		}
	}
	
	@ViewBuilder
	private func _infoRow(title: String, value: String, isLast: Bool) -> some View {
		HStack(alignment: .firstTextBaseline) {
			Text(title)
				.font(.subheadline)
				.foregroundStyle(.secondary)

			Spacer(minLength: 16)

			Text(value)
				.font(.subheadline)
				.foregroundStyle(.primary)
				.multilineTextAlignment(.trailing)
				.lineLimit(2)
		}
		.padding(.vertical, 3)

		if !isLast {
			Rectangle()
				.fill(Color.primary.opacity(0.06))
				.frame(height: 0.5)
		}
	}
	
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
		.padding(.horizontal, -16)
	}
}
