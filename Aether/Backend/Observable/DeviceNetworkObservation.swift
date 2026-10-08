import Foundation
import Network

/// NWPathMonitor supplies events; it does not decide whether the device tunnel works.
@MainActor
final class DeviceNetworkObservation {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "aether.network.monitor")

    init(onChange: @escaping @MainActor @Sendable (NWPath) -> Void) {
        monitor.pathUpdateHandler = { path in
            Task { @MainActor in onChange(path) }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }

	static func classify(_ path: NWPath) -> PhysicalNetworkState {
		guard path.status == .satisfied else { return .offline }
		if path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet) {
			return .wifiOrWired
		}
		if path.usesInterfaceType(.cellular) {
			return .cellularOnly
		}
		return .unknown
	}
}
