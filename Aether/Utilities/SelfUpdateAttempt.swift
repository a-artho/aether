import Foundation

/// Evidence for a self-install that may terminate the process before its reply.
/// An unchanged version/build is inconclusive, including same-build reinstalls.
struct SelfUpdateAttempt: Codable, Sendable {
	let bundleIdentifier: String
	let previousVersion: String
	let previousBuild: String
	let targetVersion: String
	let targetBuild: String
	var sentInstallationCommand: Bool?
	// Persisted by earlier builds; a service response also proves transmission.
	private var receivedInstallationResponse: Bool?

	init?(runningInfo: [String: Any], targetInfo: [String: Any]) {
		func value(_ info: [String: Any], _ key: String) -> String? {
			guard let text = info[key] as? String, !text.isEmpty else { return nil }
			return text
		}
		guard let identifier = value(runningInfo, "CFBundleIdentifier"),
			value(targetInfo, "CFBundleIdentifier") == identifier,
			let version = value(runningInfo, "CFBundleShortVersionString"),
			let build = value(runningInfo, "CFBundleVersion"),
			let targetVersion = value(targetInfo, "CFBundleShortVersionString"),
			let targetBuild = value(targetInfo, "CFBundleVersion") else { return nil }
		bundleIdentifier = identifier
		previousVersion = version
		previousBuild = build
		self.targetVersion = targetVersion
		self.targetBuild = targetBuild
	}

	func confirmsReplacement(runningInfo: [String: Any]) -> Bool {
		(previousVersion != targetVersion || previousBuild != targetBuild)
			&& matchesTarget(runningInfo: runningInfo)
	}

	/// The target is already running, but identical metadata cannot prove that
	/// this particular reinstall completed. Restore its action without deleting it.
	func isUnconfirmedSameBuildReinstall(runningInfo: [String: Any]) -> Bool {
		(sentInstallationCommand == true || receivedInstallationResponse == true)
			&& previousVersion == targetVersion && previousBuild == targetBuild
			&& matchesTarget(runningInfo: runningInfo)
	}

	private func matchesTarget(runningInfo: [String: Any]) -> Bool {
		runningInfo["CFBundleIdentifier"] as? String == bundleIdentifier
			&& runningInfo["CFBundleShortVersionString"] as? String == targetVersion
			&& runningInfo["CFBundleVersion"] as? String == targetBuild
	}
}
