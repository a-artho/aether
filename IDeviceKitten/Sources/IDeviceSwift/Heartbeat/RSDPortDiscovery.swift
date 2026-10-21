import Foundation
import Network

/// Resolves Remote Pairing service ports advertised on the local device network.
/// The native pairing handshake remains the authority for choosing a valid peer.
public enum RSDPortDiscovery {
    public static func resolvePorts(timeout: TimeInterval = 6,
        isCancelled: () -> Bool = { Task.isCancelled },
        stopWhen: ([UInt16]) -> Bool = { _ in false }) -> [UInt16] {
        guard timeout > 0, !isCancelled() else { return [] }
        let queue = DispatchQueue(label: "idevice.rsd-port-discovery")
        let deadline = DispatchTime.now() + timeout
        let changed = DispatchSemaphore(value: 0)
        let browser = NWBrowser(for: .bonjour(type: "_remotepairing._tcp", domain: nil), using: .tcp)
        // All mutable discovery state belongs to queue.
        var ports = Set<UInt16>()
        var discovered = Set<NWEndpoint>()
        var connections: [NWConnection] = []
        var finished = false
        var failed = false

        func resolve(_ endpoint: NWEndpoint) {
            guard !finished, discovered.insert(endpoint).inserted else { return }
            let connection = NWConnection(to: endpoint, using: .tcp)
            connection.stateUpdateHandler = { [weak connection] state in
                guard !finished, let connection else { return }
                switch state {
                case .ready:
                    let remote = connection.currentPath?.remoteEndpoint ?? connection.endpoint
                    if case let .hostPort(_, port) = remote { ports.insert(port.rawValue) }
                case .failed, .cancelled: break
                default: return
                }
                changed.signal()
            }
            connections.append(connection)
            connection.start(queue: queue)
        }
        browser.browseResultsChangedHandler = { results, _ in
            for result in results { resolve(result.endpoint) }
        }
        browser.stateUpdateHandler = { state in
            if case .failed = state { failed = true; changed.signal() }
        }
        browser.start(queue: queue)
        defer {
            queue.sync {
                finished = true
                browser.cancel()
                connections.forEach { $0.cancel() }
            }
        }
        // Keep one browser alive; short cancellable waits avoid restart gaps.
        var attempted = Set<UInt16>()
        while DispatchTime.now() < deadline, !isCancelled() {
            let next = min(deadline, DispatchTime.now() + .milliseconds(25))
            if changed.wait(timeout: next) != .success { continue }
            let snapshot = queue.sync { (ports, failed) }
            if snapshot.1 { break }
            if !snapshot.0.isSubset(of: attempted) {
                guard DispatchTime.now() < deadline, !isCancelled() else { break }
                attempted.formUnion(snapshot.0)
                if stopWhen(snapshot.0.sorted()) { break }
            }
        }
        return queue.sync { ports.sorted() }
    }
}
