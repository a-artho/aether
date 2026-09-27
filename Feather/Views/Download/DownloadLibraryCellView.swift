//
//  DownloadLibraryCellView.swift
//  Feather
//

import NukeUI
import SwiftUI

struct DownloadLibraryCellView: View {
	@Environment(\.horizontalSizeClass) private var horizontalSizeClass
	@ObservedObject var download: Download

	var body: some View {
		HStack(spacing: 18) {
			_icon

			VStack(alignment: .leading, spacing: 3) {
				Text(_title)
					.font(.headline)
					.lineLimit(1)
				Text(_subtitle)
					.font(.subheadline)
					.foregroundStyle(_isFailed ? Color.red : Color.secondary)
					.lineLimit(2)
			}
			.frame(maxWidth: .infinity, alignment: .leading)

			DownloadProgressButton(download: download)
		}
		.padding(horizontalSizeClass == .compact ? 0 : 12)
		.background {
			if horizontalSizeClass != .compact {
				RoundedRectangle(cornerRadius: 18, style: .continuous)
					.fill(Color(.quaternarySystemFill))
			}
		}
		.swipeActions(edge: .trailing, allowsFullSwipe: true) {
			if _isFailed {
				Button(.localized("Dismiss"), systemImage: "xmark", role: .destructive) {
					DownloadManager.shared.dismissDownload(download)
				}
			}
		}
		.swipeActions(edge: .leading, allowsFullSwipe: false) {
			if case .downloading = download.state {
				Button(.localized("Pause"), systemImage: "pause.fill") {
					DownloadManager.shared.pauseDownload(download)
				}
				.tint(.orange)
			}
		}
	}

	@ViewBuilder
	private var _icon: some View {
		if let iconURL = download.sourceProvenance?.sourceAppIconURL {
			LazyImage(url: iconURL) { state in
				if let image = state.image {
					image.appIconStyle(size: 57)
				} else {
					_placeholderIcon
				}
			}
			.processors([.resize(width: 114)])
		} else {
			_placeholderIcon
		}
	}

	private var _placeholderIcon: some View {
		Image("App_Unknown").appIconStyle(size: 57)
	}

	private var _title: String {
		download.sourceProvenance?.sourceAppName ?? download.fileName
	}

	private var _isFailed: Bool {
		if case .failed = download.state { return true }
		return false
	}

	private var _subtitle: String {
		switch download.state {
		case .downloading:
			guard download.totalBytes > 0 else {
				return .localized("Downloading")
			}
			return "\(download.bytesDownloaded.formattedByteCount) / \(download.totalBytes.formattedByteCount)"
		case .paused:
			return .localized("Paused")
		case .processing:
			return .localized("Processing") + " \(Int(download.overallProgress * 100))%"
		case .failed(let message):
			return message.isEmpty ? .localized("Download Failed") : message
		}
	}
}
