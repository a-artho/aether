#if !targetEnvironment(macCatalyst)
import ActivityKit
import Foundation

struct DownloadActivityAttributes: ActivityAttributes {
    enum Status: String, Codable, Hashable {
        case downloading, paused, downloaded, failed, cancelled

        var label: String {
            switch self {
            case .downloading: return "Downloading"
            case .paused: return "Paused"
            case .downloaded: return "Downloaded"
            case .failed: return "Download Failed"
            case .cancelled: return "Cancelled"
            }
        }

        var symbol: String {
            switch self {
            case .downloading: return "arrow.down"
            case .paused: return "pause.fill"
            case .downloaded: return "checkmark"
            case .failed: return "exclamationmark"
            case .cancelled: return "xmark"
            }
        }
    }

    struct ContentState: Codable, Hashable {
        var status: Status
        var bytesReceived: Int64
        var totalBytes: Int64?

        var fractionCompleted: Double? {
            guard let totalBytes, totalBytes > 0 else { return nil }
            return min(max(Double(bytesReceived) / Double(totalBytes), 0), 1)
        }

        var byteSummary: String {
            let received = ByteCountFormatter.string(fromByteCount: bytesReceived, countStyle: .file)
            guard let totalBytes, totalBytes > 0 else { return received }
            return "\(received) / \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))"
        }
    }

    let transferIdentifier: String
    let appName: String
    var tintHex: String = "#848ef9"
}
#endif
