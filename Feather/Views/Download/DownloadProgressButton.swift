//
//  DownloadProgressButton.swift
//  Feather
//

import SwiftUI

struct DownloadProgressButton: View {
	@ObservedObject var download: Download
	@ObservedObject private var downloadManager = DownloadManager.shared

	var body: some View {
		Button(action: _performAction) {
			ZStack {
				Circle()
					.stroke(Color.accentColor.opacity(0.2), lineWidth: 2.3)

				if _showsProgress {
					Circle()
						.trim(from: 0, to: download.overallProgress)
						.stroke(
							Color.accentColor,
							style: StrokeStyle(lineWidth: 2.3, lineCap: .round)
						)
						.rotationEffect(.degrees(-90))
						.animation(.smooth, value: download.overallProgress)
				}

				Image(systemName: _systemImage)
					.foregroundStyle(.tint)
					.font(.footnote.bold())
			}
			.frame(width: 31, height: 31)
		}
		.buttonStyle(.borderless)
		.disabled(!_isActionable)
		.accessibilityLabel(_accessibilityLabel)
	}

	private var _showsProgress: Bool {
		switch download.state {
		case .downloading, .processing:
			return true
		case .paused, .failed:
			return false
		}
	}

	private var _isActionable: Bool {
		switch download.state {
		case .downloading, .paused, .failed:
			return true
		case .processing:
			return false
		}
	}

	private var _systemImage: String {
		switch download.state {
		case .downloading:
			return "square.fill"
		case .paused:
			return "play.fill"
		case .processing:
			return "archivebox"
		case .failed:
			return "arrow.clockwise"
		}
	}

	private var _accessibilityLabel: String {
		switch download.state {
		case .downloading:
			return .localized("Cancel Download")
		case .paused:
			return .localized("Resume Download")
		case .processing:
			return .localized("Processing")
		case .failed:
			return .localized("Retry Download")
		}
	}

	private func _performAction() {
		switch download.state {
		case .downloading:
			downloadManager.cancelDownload(download)
		case .paused:
			downloadManager.resumeDownload(download)
		case .failed:
			downloadManager.retryDownload(download)
		case .processing:
			break
		}
	}
}
