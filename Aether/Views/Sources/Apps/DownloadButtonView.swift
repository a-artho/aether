//
//  DownloadButtonView.swift
//  Aether
//
//  Created by samsam on 7/25/25.
//

import SwiftUI
import AltSourceKit
import NimbleViews

enum RepoDownloadIconSize: Int, CaseIterable, Identifiable {
    case small = 14, medium = 16, large = 18
    var id: Self { self }
    var label: String {
        switch self {
        case .small: .localized("Small")
        case .medium: .localized("Medium")
        case .large: .localized("Large")
        }
    }
}

enum DownloadIconStyle: String, CaseIterable, Identifiable {
	case cloud, circle, arrow, save

	var id: Self { self }
	var systemImage: String {
		switch self {
		case .cloud: "icloud.and.arrow.down"
		case .circle: "arrow.down.circle"
		case .arrow: "arrow.down"
		case .save: "square.and.arrow.down"
		}
	}
	var title: String {
		switch self {
		case .cloud: .localized("Cloud")
		case .circle: .localized("Circle")
		case .arrow: .localized("Arrow")
		case .save: .localized("Save")
		}
	}
}

struct DownloadButtonView: View {
	enum Style {
		case compact
		case navigation
	}

	let sourceURL: URL?
	let source: ASRepository?
	let app: ASRepository.App
	var style: Style = .compact
	@AppStorage("Aether.downloadIconStyle") private var iconStyle: DownloadIconStyle = .cloud
	@AppStorage("Aether.repoDownloadIconSize") private var iconSize: RepoDownloadIconSize = .large
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
						Image(systemName: iconStyle.systemImage)
							.foregroundStyle(_themeColor)
                            .font(.system(size: CGFloat(iconSize.rawValue), weight: .semibold))
							.frame(width: 44, height: 44)
							.contentShape(Rectangle())
					case .navigation:
						Image(systemName: iconStyle.systemImage)
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
