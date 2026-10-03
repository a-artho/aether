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
		case prominent
		case navigation
	}

	let sourceURL: URL?
	let source: ASRepository?
	let app: ASRepository.App
	var style: Style = .compact
	@ObservedObject private var downloadManager = DownloadManager.shared

	private var currentDownload: Download? {
		guard let url = app.currentDownloadUrl else { return nil }
		return downloadManager.getDownload(from: url, sourceProvenance: _sourceProvenance())
	}

	var body: some View {
		ZStack {
			if let currentDownload {
				DownloadProgressButton(download: currentDownload)
					.compatTransition()
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
							.font(.system(size: 18, weight: .semibold))
							.foregroundStyle(_themeColor)
							.frame(width: 44, height: 44)
							.contentShape(Rectangle())
					case .prominent:
						Image(systemName: "icloud.and.arrow.down")
							.font(.footnote.bold())
							.foregroundStyle(_themeColor)
							.frame(width: 35, height: 35)
							.background(Color(uiColor: .quaternarySystemFill))
							.clipShape(Circle())
							.frame(width: 44, height: 44)
							.contentShape(Rectangle())
					case .navigation:
						Image(systemName: "icloud.and.arrow.down")
							.fontWeight(.semibold)
							.foregroundStyle(_themeColor)
					}
				}
				.buttonStyle(.borderless)
				.tint(_themeColor)
				.compatTransition()
			}
		}
		.animation(.easeInOut(duration: 0.3), value: currentDownload != nil)
	}

	private var _themeColor: Color {
		Color(hex: UserDefaults.standard.string(forKey: "Aether.userTintColor") ?? "#848ef9")
	}

	private func _sourceProvenance() -> SourceAppProvenance? {
		guard let source else { return nil }
		return SourceAppProvenance(sourceURL: sourceURL, repository: source, app: app)
	}
}
