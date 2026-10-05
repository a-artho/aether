#if !targetEnvironment(macCatalyst)
import UIKit

/// Brief execution only for saving a state transition or resume token.
/// This never replaces the continued task that owns the download operation.
@MainActor
final class DownloadCheckpointLease {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    init() {
        guard UIApplication.shared.applicationState != .active else { return }
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Save download state") { [weak self] in
            Task { @MainActor in self?.end() }
        }
    }
    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
#endif
