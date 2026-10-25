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

	private var currentDownload: Download? {
		guard let url = app.currentDownloadUrl else { return nil }
		return downloadManager.getDownload(from: url, sourceProvenance: _sourceProvenance())
	}

	var body: some View {
		ZStack {
			if let currentDownload {
				DownloadProgressButton(download: currentDownload)
					.transition(reduceMotion ? .identity : .opacity)
			} else {
				Button {
					if let url = app.currentDownloadUrl {
						Task {
							_ = await downloadManager.startDownload(
								from: url,
								id: app.currentUniqueId,
								sourceProvenance: _sourceProvenance()
							)
						}
					}
				} label: {
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
	}

	private var _themeColor: Color {
		Color(hex: themeHex)
	}

	private func _sourceProvenance() -> SourceAppProvenance? {
		guard let source else { return nil }
		return SourceAppProvenance(sourceURL: sourceURL, repository: source, app: app)
	}
}
