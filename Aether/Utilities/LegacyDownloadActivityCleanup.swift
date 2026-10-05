#if !targetEnvironment(macCatalyst)
import ActivityKit
import UIKit

/// Migration only: native continued tasks now provide all download presentation.
@MainActor
func retireLegacyDownloadActivities() {
    let activities = Activity<DownloadActivityAttributes>.activities
    guard !activities.isEmpty else { return }
    let lease = UIApplication.shared.beginBackgroundTask(withName: "Retire old download activities", expirationHandler: nil)
    Task {
        defer { if lease != .invalid { UIApplication.shared.endBackgroundTask(lease) } }
        for activity in activities { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
#endif
