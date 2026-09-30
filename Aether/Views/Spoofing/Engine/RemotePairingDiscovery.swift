import Foundation
import Network

enum RemotePairingDiscovery {
    /// Bonjour can include other devices. Return candidate ports only; the
	/// the device endpoint validation decides which is valid.
    static func resolvePorts(timeout: TimeInterval = 6) -> [UInt16] {
		let queue = DispatchQueue(label: "aether.spoofing.remote-pairing-discovery")
        let deadline = DispatchTime.now() + timeout
        let browseDeadline = DispatchTime.now() + max(0, timeout - 1.5)
        var endpoints: [NWEndpoint] = []
        var matchedBrowser: NWBrowser?

        // The first Bonjour browse can fail while iOS is showing the Local
        // Network permission prompt. Retry within a bounded discovery window.
        while DispatchTime.now() < browseDeadline, endpoints.isEmpty {
            let browseReady = DispatchSemaphore(value: 0)
            let browser = NWBrowser(for: .bonjour(type: "_remotepairing._tcp", domain: nil), using: .tcp)
            var browseSignaled = false
            browser.browseResultsChangedHandler = { results, _ in
                guard !results.isEmpty, !browseSignaled else { return }
                browseSignaled = true
                queue.asyncAfter(deadline: .now() + 0.25) { browseReady.signal() }
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state { browseReady.signal() }
            }
            browser.start(queue: queue)
            let slice = DispatchTime.now() + 1.25
            _ = browseReady.wait(timeout: slice < browseDeadline ? slice : browseDeadline)
            endpoints = queue.sync { browser.browseResults.map(\.endpoint) }
            if endpoints.isEmpty {
                browser.cancel()
            } else {
                matchedBrowser = browser
            }
            if endpoints.isEmpty, DispatchTime.now() < browseDeadline {
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        guard !endpoints.isEmpty else {
            return []
        }

        let resolved = DispatchSemaphore(value: 0)
        var completed = Set<Int>()
        var ports = Set<UInt16>()
        var connections: [NWConnection] = []

        for (index, endpoint) in endpoints.enumerated() {
            let connection = NWConnection(to: endpoint, using: .tcp)
            connection.stateUpdateHandler = { [weak connection] state in
                guard let connection else { return }
                switch state {
                case .ready:
                    let remote = connection.currentPath?.remoteEndpoint ?? connection.endpoint
                    if case let .hostPort(_, port) = remote {
                        ports.insert(port.rawValue)
                    }
                case .failed, .cancelled:
                    break
                default:
                    return
                }
                guard completed.insert(index).inserted else { return }
                if completed.count == endpoints.count { resolved.signal() }
            }
            connections.append(connection)
            connection.start(queue: queue)
        }

        _ = resolved.wait(timeout: deadline)
        let result = queue.sync { ports.sorted() }
        connections.forEach { $0.cancel() }
        matchedBrowser?.cancel()
        return result
    }
}
