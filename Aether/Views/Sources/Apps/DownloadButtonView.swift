//
//  DownloadButtonView.swift
//  Aether
//
//  Created by samsam on 7/25/25.
//

import SwiftUI
import AltSourceKit
import NimbleViews

enum DownloadIconStyle: String, CaseIterable, Identifiable {
    case current, safari
    var id: Self { self }
    var label: String {
        switch self {
        case .current: .localized("Current")
        case .safari: .localized("Safari")
        }
    }
}

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

struct DownloadButtonView: View {
	enum Style {
		case compact
		case navigation
	}

	let sourceURL: URL?
	let source: ASRepository?
	let app: ASRepository.App
	var style: Style = .compact
	@AppStorage("Aether.repoDownloadIconSize") private var iconSize: RepoDownloadIconSize = .large
	@AppStorage("Aether.downloadIconStyle") private var iconStyle: DownloadIconStyle = .current
	@AppStorage("Aether.userTintColor") private var themeHex = "#848ef9"
	@ObservedObject private var downloadManager = DownloadManager.shared

	private var currentDownload: Download? {
		guard let url = app.currentDownloadUrl else { return nil }
		return downloadManager.getDownload(from: url, sourceProvenance: _sourceProvenance())
	}

	var body: some View {
		ZStack {
			if let currentDownload {
				DownloadProgressButton(download: currentDownload)
					.transition(.blurReplace)
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
						Group {
                            if iconStyle == .safari {
                                Image(systemName: "arrow.down.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(Color(uiColor: .systemBackground), _themeColor)
                            } else {
                                Image(systemName: "icloud.and.arrow.down").foregroundStyle(_themeColor)
                            }
                        }
                            .font(.system(size: CGFloat(iconSize.rawValue), weight: .semibold))
							.frame(width: 44, height: 44)
							.contentShape(Rectangle())
					case .navigation:
						Image(systemName: iconStyle == .safari ? "arrow.down" : "icloud.and.arrow.down")
							.fontWeight(.semibold)
							.foregroundStyle(_themeColor)
					}
				}
				.buttonStyle(.borderless)
				.accessibilityLabel(String.localized("Download"))
				.tint(_themeColor)
				.transition(.blurReplace)
			}
		}
		.animation(.easeInOut(duration: 0.3), value: currentDownload != nil)
	}

	private var _themeColor: Color {
		Color(hex: themeHex)
	}

	private func _sourceProvenance() -> SourceAppProvenance? {
		guard let source else { return nil }
		return SourceAppProvenance(sourceURL: sourceURL, repository: source, app: app)
	}
}
