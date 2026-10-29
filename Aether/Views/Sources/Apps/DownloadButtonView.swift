//
//  DownloadButtonView.swift
//  Aether
//
//  Created by samsam on 7/25/25.
//

import SwiftUI
import AltSourceKit
import NimbleViews

struct DownloadButtonView: View {
	enum Style {
		case compact
		case navigation
	}

	let sourceURL: URL?
	let source: ASRepository?
	let app: ASRepository.App
	var style: Style = .compact
	@AppStorage("Aether.userTintColor") private var themeHex = "#848ef9"
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@ObservedObject private var downloadManager = DownloadManager.shared
	@ObservedObject private var libraryDownloads = SourceLibraryDownloads.shared

	private var currentDownload: Download? {
		guard let url = app.currentDownloadUrl else { return nil }
		return downloadManager.getDownload(from: url, sourceProvenance: _sourceProvenance())
	}

	private var isInLibrary: Bool { libraryDownloads.contains(_sourceProvenance()) }

	var body: some View {
		ZStack {
			if let currentDownload {
				DownloadProgressButton(download: currentDownload)
					.transition(reduceMotion ? .identity : .opacity)
			} else if isInLibrary {
				ZStack {
					Circle().stroke(lineWidth: 2.3)
					Image(systemName: "checkmark")
						.font(.footnote.bold())
				}
				.frame(width: 31, height: 31)
				.foregroundStyle(style == .navigation ? Color.primary : _themeColor)
				.frame(width: 44, height: 44)
				.contentShape(Rectangle())
				.accessibilityElement(children: .ignore)
				.accessibilityLabel(String.localized("In Library"))
				.transition(reduceMotion ? .identity : .opacity)
			} else {
				Button(action: _startDownload) {
					switch style {
					case .compact:
						Image(systemName: "icloud.and.arrow.down")
							.foregroundStyle(_themeColor)
							.font(.system(size: 16, weight: .semibold))
							.frame(width: 44, height: 44)
							.contentShape(Rectangle())
					case .navigation:
						Image(systemName: "icloud.and.arrow.down")
							.fontWeight(.semibold)
							.foregroundStyle(.primary)
					}
				}
				.buttonStyle(.borderless)
				.accessibilityLabel(String.localized("Download"))
				.tint(style == .navigation ? Color.primary : _themeColor)
				.transition(reduceMotion ? .identity : .opacity)
			}
		}
		.animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: currentDownload != nil)
		.animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isInLibrary)
		.contextMenu {
			SourceDownloadAgainAction(sourceURL: sourceURL, source: source, app: app)
		}
		.accessibilityActions {
			if isInLibrary {
				Button(String.localized("Download Again"), action: _startDownload)
			}
		}
	}

	private func _startDownload() {
		guard let url = app.currentDownloadUrl else { return }
		Task {
			_ = await downloadManager.startDownload(from: url, id: app.currentUniqueId,
				sourceProvenance: _sourceProvenance())
		}
	}

	private var _themeColor: Color {
		Color(hex: themeHex)
	}

	private func _sourceProvenance() -> SourceAppProvenance? {
		guard let source else { return nil }
		return SourceAppProvenance(sourceURL: sourceURL, repository: source, app: app)
	}
}

/// Shared by the SwiftUI update rows and the detail toolbar control.
struct SourceDownloadAgainAction: View {
	let sourceURL: URL?
	let source: ASRepository?
	let app: ASRepository.App
	@ObservedObject private var libraryDownloads = SourceLibraryDownloads.shared

	var body: some View {
		let provenance = source.flatMap { SourceAppProvenance(sourceURL: sourceURL, repository: $0, app: app) }
		if libraryDownloads.contains(provenance), let url = app.currentDownloadUrl {
			Button {
				Task {
					_ = await DownloadManager.shared.startDownload(from: url,
						id: app.currentUniqueId, sourceProvenance: provenance)
				}
			} label: {
				Label(String.localized("Download Again"), systemImage: "arrow.down")
			}
		}
	}
}
