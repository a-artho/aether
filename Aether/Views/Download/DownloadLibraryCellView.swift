//
//  DownloadLibraryCellView.swift
//  Aether
//

import NukeUI
import SwiftUI

struct DownloadLibraryCellView: View {
	@Environment(\.horizontalSizeClass) private var horizontalSizeClass
	@ObservedObject var download: Download

	var body: some View {
		HStack(spacing: 18) {
			_icon

			LibraryRowDetails(
				name: _title,
				version: download.sourceProvenance?.sourceAppVersion,
				identifier: download.sourceProvenance?.sourceAppIdentifier,
				secondaryStatus: _subtitle,
				isFailed: _isFailed
			)

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
			Button(.localized("Delete"), systemImage: "trash", role: .destructive) {
				DownloadManager.shared.deleteDownload(download)
			}
		}
	}

	@ViewBuilder
	private var _icon: some View {
		if let iconURL = download.sourceProvenance?.sourceAppIconURL {
			LazyImage(url: iconURL) { state in
				if let image = state.image {
					image.appIconStyle(size: 50)
				} else {
					_placeholderIcon
				}
			}
			.processors([.resize(width: 100)])
		} else {
			_placeholderIcon
		}
	}

	private var _placeholderIcon: some View {
		Image("App_Unknown").appIconStyle(size: 50)
	}

	private var _title: String {
		download.sourceProvenance?.sourceAppName ?? download.fileName
	}

	private var _isFailed: Bool {
		if case .failed(_, _) = download.state { return true }
		return false
	}

	private var _subtitle: String {
		switch download.state {
		case .downloading:
			guard download.totalBytes > 0 else {
				return .localized("Downloading")
			}
			return "\(download.bytesDownloaded.formattedByteCount) / \(download.totalBytes.formattedByteCount)"
		case .pausing:
			return .localized("Pausing")
		case .paused:
			return .localized("Paused")
		case .resuming:
			return .localized("Resuming")
		case .processing:
			if download.waitingForForeground { return .localized("Waiting for Aether to Open") }
			return .localized("Processing") + " \(Int(download.overallProgress * 100))%"
		case .failed(let message, _):
			return message.isEmpty ? .localized("Download Failed") : message
		}
	}
}
