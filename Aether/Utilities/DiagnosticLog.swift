import Foundation
import OSLog

/// Records infrequent failures from workers without crossing UI isolation.
enum DiagnosticLog {
    static func error(_ message: String, category: String) {
        Logger.misc.error("[\(category, privacy: .public)] \(message, privacy: .public)")
        Task { @MainActor in
            DebugLogManager.shared.log(message, category: category, level: .error)
        }
    }
}
