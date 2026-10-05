import Foundation

/// Feather-compatible progress lifecycle. A zero (including unavailable progress)
/// after a positive reading ends the UI operation, without verifying installation.
struct ServerInstallProgress {
	private(set) var hasStarted = false

	mutating func observe(progress: Double?) -> Bool {
		let raw = progress ?? 0
		if raw > 0 { hasStarted = true }
		return hasStarted && raw == 0
	}
}
