#if !targetEnvironment(macCatalyst)
import ActivityKit
import Foundation
import UIKit

/// Presentation only. Ending or dismissing this activity never cancels a URLSession transfer.
@MainActor
final class DownloadActivityManager {
    static let shared = DownloadActivityManager()
    private typealias DownloadActivity = Activity<DownloadActivityAttributes>

    private final class Entry {
        let activity: DownloadActivity
        var pending: (DownloadActivityAttributes.ContentState, Bool)?
        var worker: Task<Void, Never>?
        var lastUpdate: TimeInterval = 0
        var isEnding = false
        init(_ activity: DownloadActivity) { self.activity = activity }
    }

    @MainActor
    private final class PublicationLease {
        private var identifier: UIBackgroundTaskIdentifier = .invalid
        init() {
            guard UIApplication.shared.applicationState == .background else { return }
            identifier = UIApplication.shared.beginBackgroundTask(withName: "Download activity update") { [weak self] in
                Task { @MainActor in self?.end() }
            }
        }
        func end() {
            guard identifier != .invalid else { return }
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
    }

    private var entries: [String: Entry] = [:]
    private var dismissedTransfers = Set<String>()

    func start(_ download: Download) {
        dismissedTransfers.remove(download.id)
        if let entry = entries[download.id], entry.activity.activityState == .dismissed || entry.activity.activityState == .ended {
            entries.removeValue(forKey: download.id)
        }
        update(download)
    }

    func update(_ download: Download) {
        guard !download.onlyArchiving else { return }
        switch download.state {
        case .downloading, .resuming, .pausing:
            publish(download, status: .downloading, ending: false)
        case .paused:
            finish(download, status: .paused)
        case .processing:
            finish(download, status: .downloaded)
        case .failed:
            finish(download, status: .failed)
        }
    }

    func finish(_ download: Download, status: DownloadActivityAttributes.Status) {
        publish(download, status: status, ending: true)
    }

    /// Reattach existing activities after a background URLSession relaunch; remove orphaned ones.
    func reconcile(_ downloads: [Download]) {
        let identifiers = Set(downloads.map(\.id))
        dismissedTransfers.formIntersection(identifiers)
        for identifier in Array(entries.keys) where !identifiers.contains(identifier) {
            let entry = entries.removeValue(forKey: identifier)
            entry?.pending = nil
            entry?.worker?.cancel()
        }
        for activity in DownloadActivity.activities where !identifiers.contains(activity.attributes.transferIdentifier) {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
        for download in downloads { update(download) }
    }

    private func publish(_ download: Download, status: DownloadActivityAttributes.Status, ending: Bool) {
        guard !download.onlyArchiving, !dismissedTransfers.contains(download.id) else { return }
        let state = DownloadActivityAttributes.ContentState(status: status,
            bytesReceived: max(0, download.bytesDownloaded),
            totalBytes: download.totalBytes > 0 ? download.totalBytes : nil)
        let identifier = download.id
        let entry: Entry
        if let existing = entries[identifier] {
            entry = existing
        } else if let activity = DownloadActivity.activities.first(where: {
            $0.attributes.transferIdentifier == identifier && ($0.activityState == .active || $0.activityState == .stale)
        }) {
            entry = Entry(activity)
            entries[identifier] = entry
        } else {
            // ActivityKit requests require foreground execution. Restoration in the background
            // can update an existing activity, but must not create one or stop the download.
            guard !ending, UIApplication.shared.applicationState == .active,
                  ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            do {
                let activity = try DownloadActivity.request(attributes: .init(
                    transferIdentifier: identifier,
                    appName: download.sourceProvenance?.sourceAppName ?? download.fileName,
                    tintHex: UserDefaults.standard.string(forKey: "Aether.userTintColor") ?? "#848ef9"),
                    content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(60)), pushType: nil)
                entry = Entry(activity)
                entries[identifier] = entry
                DebugLogManager.shared.log("Download Live Activity started.", category: "Download")
            } catch {
                // A denied request must not be retried on every progress callback.
                dismissedTransfers.insert(identifier)
                DebugLogManager.shared.log("Download Live Activity unavailable: \(error.localizedDescription)", category: "Download", level: .notice)
                return
            }
        }
        guard !entry.isEnding else { return }
        if entry.activity.activityState == .dismissed || entry.activity.activityState == .ended {
            dismissedTransfers.insert(identifier)
            entries.removeValue(forKey: identifier)
            return
        }
        let now = Date.timeIntervalSinceReferenceDate
        // URLSession progress arrives frequently. Publish at most once per second, with
        // one coalescing worker per activity; terminal changes bypass this limit.
        guard ending || now - entry.lastUpdate >= 1 else { return }
        entry.lastUpdate = now
        entry.isEnding = ending
        entry.pending = (state, ending)
        guard entry.worker == nil else { return }
        // Protect the brief ActivityKit update/end during a URLSession background wake.
        // This lease is only for publishing UI; it never owns the network operation.
        let publicationLease = PublicationLease()
        entry.worker = Task { [weak self] in
            defer { publicationLease.end() }
            while !Task.isCancelled, let (state, ending) = entry.pending {
                entry.pending = nil
                let content = ActivityContent(state: state,
                    staleDate: ending ? nil : Date().addingTimeInterval(60))
                if ending {
                    let dismiss: ActivityUIDismissalPolicy = state.status == .downloaded || state.status == .cancelled
                        ? .immediate : .after(Date().addingTimeInterval(30))
                    await entry.activity.end(content, dismissalPolicy: dismiss)
                    if self?.entries[identifier] === entry { self?.entries.removeValue(forKey: identifier) }
                    return
                }
                await entry.activity.update(content)
            }
            entry.worker = nil
        }
    }
}
#endif
