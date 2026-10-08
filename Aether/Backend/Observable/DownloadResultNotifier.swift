import UIKit
import UserNotifications

/// Owns notification permission and result delivery separately from transfers.
@MainActor
final class DownloadResultNotifier {
    static let shared = DownloadResultNotifier()
    private var requestingNotificationPermission = false
    private init() {}

	func requestPermissionIfNeeded() {
        #if !targetEnvironment(macCatalyst)
		guard UIApplication.shared.applicationState == .active, !requestingNotificationPermission else { return }
		requestingNotificationPermission = true
		Task {
			defer { requestingNotificationPermission = false }
			let center = UNUserNotificationCenter.current()
			let settings = await center.notificationSettings()
			guard settings.authorizationStatus == .notDetermined,
				UIApplication.shared.applicationState == .active else { return }
			do {
				_ = try await center.requestAuthorization(options: [.alert, .sound])
			} catch {
				DebugLogManager.shared.log("Download notification permission failed: \(error.localizedDescription)", category: "Download", level: .notice)
			}
		}
	    #endif
	}

	func send(transferIdentifier: String, title: String, body: String) {
		#if !targetEnvironment(macCatalyst)
		let content = UNMutableNotificationContent()
		content.title = title
		content.body = body
		content.sound = .default
		let request = UNNotificationRequest(identifier: "Aether.download.result.\(transferIdentifier)", content: content, trigger: nil)
		let checkpoint = DownloadCheckpointLease()
		Task {
			defer { checkpoint.end() }
			do {
				try await UNUserNotificationCenter.current().add(request)
				DebugLogManager.shared.log("Download result notification submitted id=\(transferIdentifier) title=\(title).", category: "Download", level: .info)
			} catch {
				DebugLogManager.shared.log("Download result notification failed id=\(transferIdentifier): \(error.localizedDescription)", category: "Download", level: .notice)
			}
		}
		#endif
	}
}
