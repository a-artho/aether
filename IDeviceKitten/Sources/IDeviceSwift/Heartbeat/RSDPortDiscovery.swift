import Foundation
import Network

/// Resolves Remote Pairing service ports advertised on the local device network.
/// The native pairing handshake remains the authority for choosing a valid peer.
public enum RSDPortDiscovery {
	public static func resolvePorts(timeout: TimeInterval = 6) -> [UInt16] {
		let queue = DispatchQueue(label: "idevice.rsd-port-discovery")
		let deadline = DispatchTime.now() + timeout
		// Leave at least half a second for endpoint resolution while preserving the
		// old 75/25 browse-versus-resolve split for the normal six-second path.
		// A 1.5-second fast probe therefore still gets one full second of Bonjour
		// discovery instead of silently skipping it.
		let browseBudget = max(0, min(timeout * 0.75, timeout - 0.5))
		let browseDeadline = DispatchTime.now() + browseBudget
		var endpoints: [NWEndpoint] = []
		var matchedBrowser: NWBrowser?

		while DispatchTime.now() < browseDeadline, endpoints.isEmpty {
			let browseReady = DispatchSemaphore(value: 0)
			let browser = NWBrowser(
				for: .bonjour(type: "_remotepairing._tcp", domain: nil),
				using: .tcp
			)
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

		guard !endpoints.isEmpty else { return [] }

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
