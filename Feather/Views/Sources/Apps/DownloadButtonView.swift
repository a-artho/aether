//
//  DownloadButtonView.swift
//  Feather
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

	var body: some View {
		ZStack {
			if let currentDownload = downloadManager.getDownload(by: app.currentUniqueId) {
				DownloadProgressButton(download: currentDownload)
					.compatTransition()
			} else {
				Button {
					if let url = app.currentDownloadUrl {
						_ = downloadManager.startDownload(
							from: url,
							id: app.currentUniqueId,
							sourceProvenance: _sourceProvenance()
						)
					}
				} label: {
					switch style {
					case .compact, .prominent:
						Image(systemName: "icloud.and.arrow.down")
							.font(.footnote.bold())
							.foregroundStyle(_themeColor)
							.frame(width: 31, height: 31)
							.background(Color(uiColor: .quaternarySystemFill))
							.clipShape(Circle())
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
		.animation(.easeInOut(duration: 0.3), value: downloadManager.getDownload(by: app.currentUniqueId) != nil)
	}

	private var _themeColor: Color {
		Color(hex: UserDefaults.standard.string(forKey: "Feather.userTintColor") ?? "#848ef9")
	}

	private func _sourceProvenance() -> SourceAppProvenance? {
		guard let source else { return nil }
		return SourceAppProvenance(sourceURL: sourceURL, repository: source, app: app)
	}
}
