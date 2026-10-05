// Legacy schema retained solely to end activities created by older builds.
#if !targetEnvironment(macCatalyst)
import ActivityKit

struct DownloadActivityAttributes: ActivityAttributes {
    enum Status: String, Codable, Hashable { case downloading, paused, downloaded, failed, cancelled }
    struct ContentState: Codable, Hashable {
        var status: Status
        var bytesReceived: Int64
        var totalBytes: Int64?
    }
    let transferIdentifier: String
    let appName: String
    var tintHex: String = "#848ef9"
}
#endif
