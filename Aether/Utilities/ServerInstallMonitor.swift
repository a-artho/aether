import Foundation

/// Progress disappearance is a cue to verify, never a success result itself.
struct ServerInstallMonitor {
	struct InstalledState: Equatable {
		let installed: Bool
		let version: String?
		let registeredAt: Date?
	}
	enum Outcome: Equatable { case waiting, success, failed(String) }
	let expectedVersion: String?
	let previous: InstalledState?
	let startedAt: TimeInterval
	var startTimeout: TimeInterval = 120
	var totalTimeout: TimeInterval = 1800
	var verificationTimeout: TimeInterval = 30
	private(set) var hasStarted = false
	private var verifyingSince: TimeInterval?

	init(expectedVersion: String?, previous: InstalledState?, startedAt: TimeInterval) {
		self.expectedVersion = expectedVersion
		self.previous = previous
		self.startedAt = startedAt
	}

	mutating func observe(progress: Double?, installed: InstalledState?, now: TimeInterval) -> Outcome {
		let value = progress.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
		if let value, value > 0 {
			hasStarted = true
			if value >= 1 { verifyingSince = verifyingSince ?? now }
			else { verifyingSince = nil }
		} else if hasStarted { verifyingSince = verifyingSince ?? now }
		if let installed, installed.installed,
			let version = expectedVersion, installed.version == version {
			let changedVersion = previous?.installed == false || (previous != nil && previous?.version != version)
			let changedRegistration = installed.registeredAt != nil && previous != nil && installed.registeredAt != previous?.registeredAt
			// Do not mistake an unchanged pre-existing copy for a successful reinstall.
			if changedVersion || changedRegistration { return .success }
		}
		if !hasStarted, now - startedAt >= startTimeout { return .failed("iOS did not start installation. Retry the installation.") }
		if let since = verifyingSince, now - since >= verificationTimeout {
			return .failed("Aether could not verify that the requested app version was installed. Check the device before retrying.")
		}
		if now - startedAt >= totalTimeout { return .failed("Installation timed out. Check the device before retrying.") }
		return .waiting
	}
}
