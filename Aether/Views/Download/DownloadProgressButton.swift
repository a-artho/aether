//
//  DownloadProgressButton.swift
//  Aether
//

import SwiftUI

enum ActionProgressRingMetrics {
	static let diameter: CGFloat = 35
}

struct DownloadProgressButton: View {
	@ObservedObject var download: Download
	@ObservedObject private var downloadManager = DownloadManager.shared
	var showsTrack = true

	init(download: Download, showsTrack: Bool = true) {
		self.download = download
		self.showsTrack = showsTrack
	}

	var body: some View {
		Button(action: _performAction) {
			ZStack {
				if showsTrack {
					Circle()
						.stroke(Color.accentColor.opacity(0.2), lineWidth: 2.3)
				}

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

				if download.isPreparingSource && !download.waitingForForeground {
					ProgressView().controlSize(.small).tint(.accentColor)
				} else {
					Image(systemName: _systemImage)
						.foregroundStyle(.tint)
						.font(.footnote.bold())
				}
			}
			.frame(width: ActionProgressRingMetrics.diameter, height: ActionProgressRingMetrics.diameter)
			.frame(width: 44, height: 44, alignment: showsTrack ? .center : .trailing)
			.contentShape(Rectangle())
		}
		.buttonStyle(.borderless)
		.disabled(!_isActionable)
		.accessibilityLabel(_accessibilityLabel)
		.accessibilityValue(_showsProgress
			? String.localized("%lld%% complete", arguments: Int((download.overallProgress * 100).rounded()))
			: "")
	}

	private var _showsProgress: Bool {
		switch download.state {
		case .downloading, .pausing, .resuming, .processing:
			return true
		case .paused, .failed:
			return false
		}
	}

	private var _isActionable: Bool {
		switch download.state {
		case .downloading, .paused, .failed:
			return true
		case .pausing, .resuming, .processing:
			return false
		}
	}

	private var _systemImage: String {
		switch download.state {
		case .downloading:
			return "pause.fill"
		case .pausing, .resuming:
			return "hourglass"
		case .paused:
			return "play.fill"
		case .processing:
			if download.waitingForForeground { return "hourglass" }
			return "archivebox"
		case .failed:
			return "arrow.clockwise"
		}
	}

	private var _accessibilityLabel: String {
		switch download.state {
		case .downloading:
			return .localized("Pause Download")
		case .pausing:
			return .localized("Pausing Download")
		case .paused:
			return .localized("Resume Download")
		case .resuming:
			return .localized("Resuming Download")
		case .processing:
			return .localized("Processing")
		case .failed(_, let action):
			switch action {
			case .resume: return .localized("Resume Download")
			case .restart: return .localized("Restart Download")
			case .retryProcessing: return .localized("Retry Processing")
			}
		}
	}

	private func _performAction() {
		switch download.state {
		case .downloading:
			downloadManager.pauseDownload(download)
		case .paused:
			Task { await downloadManager.resumeDownload(download) }
		case .failed:
			Task { await downloadManager.retryDownload(download) }
		case .pausing, .resuming, .processing:
			break
		}
	}
}
