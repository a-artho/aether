import Foundation
import IDevice
import IDeviceSwift

enum LocationEngineError: LocalizedError {
    case invalidIP
    case pairingRead(String?)
    case tunnelCreate(String?)
    case remoteServer(String?)
    case simulationCreate(String?)
    case locationSet(String?)
    case locationClear(String?)
    case notActive

    var mayHaveChangedLocation: Bool {
        if case .locationSet = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .invalidIP: return "The device tunnel address is invalid."
        case .pairingRead(let detail): return Self.describe("Could not read the RPPairing file.", detail)
        case .tunnelCreate(let detail): return Self.describe("Could not open the developer tunnel.", detail)
        case .remoteServer(let detail): return Self.describe("Connected to the tunnel but RemoteXPC handshake failed.", detail)
        case .simulationCreate(let detail): return Self.describe("Could not open Apple’s location simulation service.", detail)
        case .locationSet(let detail): return Self.describe("Failed to set simulated coordinates.", detail)
        case .locationClear(let detail): return Self.describe("Could not confirm the simulated location was cleared. Reconnect the device tunnel and try again.", detail)
        case .notActive: return "No active simulation session."
        }
    }

    private static func describe(_ message: String, _ detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return message }
        return "\(message) \(detail)"
    }
}

enum LocationConnectionStage: Sendable {
    case findingService
    case openingTunnel
    case settingLocation

    var label: String {
        switch self {
        case .findingService: return "Finding pairing service…"
        case .openingTunnel: return "Opening developer tunnel…"
        case .settingLocation: return "Setting location…"
        }
    }
}

/// Thin Swift wrapper around idevice’s DVT location simulation (injects into locationd).
enum LocationEngine {
    private static let session = NativeLocationSession()
    static func set(latitude: Double, longitude: Double, pairingPath: String, deviceIP: String,
                    progress: @escaping @Sendable (LocationConnectionStage) -> Void = { _ in }) async -> Result<Void, LocationEngineError> {
        await session.set(latitude: latitude, longitude: longitude, pairingPath: pairingPath, deviceIP: deviceIP, progress: progress)
    }
    static func clear(pairingPath: String, deviceIP: String, verifyRemotely: Bool) async -> Result<Void, LocationEngineError> {
        await session.clear(pairingPath: pairingPath, deviceIP: deviceIP, verifyRemotely: verifyRemotely)
    }
}

// Every native handle is accessed exclusively on this serial queue.
private final class NativeLocationSession: @unchecked Sendable {
	private let queue = DispatchQueue(label: "aether.spoofing.location", qos: .userInitiated)

    private var adapter: OpaquePointer?
    private var handshake: OpaquePointer?
    private var remoteServer: OpaquePointer?
    private var locationSimulation: OpaquePointer?

    func set(
        latitude: Double,
        longitude: Double,
        pairingPath: String,
        deviceIP: String,
        progress: @escaping @Sendable (LocationConnectionStage) -> Void = { _ in }
    ) async -> Result<Void, LocationEngineError> {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let result = setLocked(
                    latitude: latitude,
                    longitude: longitude,
                    pairingPath: pairingPath,
                    deviceIP: deviceIP,
                    progress: progress
                )
                continuation.resume(returning: result)
            }
        }
    }

    func clear(
        pairingPath: String,
        deviceIP: String,
        verifyRemotely: Bool
    ) async -> Result<Void, LocationEngineError> {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: clearLocked(
                    pairingPath: pairingPath,
                    deviceIP: deviceIP,
                    verifyRemotely: verifyRemotely
                ))
            }
        }
    }

    private func cleanup() {
        if let locationSimulation {
            location_simulation_free(locationSimulation)
            self.locationSimulation = nil
        }
        if let remoteServer {
            remote_server_free(remoteServer)
            self.remoteServer = nil
        }
        if let handshake {
            rsd_handshake_free(handshake)
            self.handshake = nil
        }
        if let adapter {
            adapter_free(adapter)
            self.adapter = nil
        }
    }

    private func setLocked(
        latitude: Double,
        longitude: Double,
        pairingPath: String,
        deviceIP: String,
        progress: @Sendable (LocationConnectionStage) -> Void
    ) -> Result<Void, LocationEngineError> {
        if let locationSimulation {
            progress(.settingLocation)
            if let err = location_simulation_set(locationSimulation, latitude, longitude) {
                idevice_error_free(err)
                cleanup()
            } else {
                return .success(())
            }
        }

        switch openSessionLocked(pairingPath: pairingPath, deviceIP: deviceIP, progress: progress) {
        case .failure(let error): return .failure(error)
        case .success: break
        }

        progress(.settingLocation)
        if let setError = location_simulation_set(locationSimulation, latitude, longitude) {
            let detail = ffiErrorDetail(setError)
            idevice_error_free(setError)
            cleanup()
            return .failure(.locationSet(detail))
        }
        return .success(())
    }

    private func openSessionLocked(
        pairingPath: String,
        deviceIP: String,
        progress: @Sendable (LocationConnectionStage) -> Void
    ) -> Result<Void, LocationEngineError> {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        let inetResult = deviceIP.withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
        guard inetResult == 1 else { return .failure(.invalidIP) }

        var pairingHandle: OpaquePointer?
        if let pairingError = pairingPath.withCString({ rp_pairing_file_read($0, &pairingHandle) }) {
            let detail = ffiErrorDetail(pairingError)
            idevice_error_free(pairingError)
            return .failure(.pairingRead(detail))
        }
        guard let pairingHandle else { return .failure(.pairingRead(nil)) }
        defer { rp_pairing_file_free(pairingHandle) }

		progress(.findingService)
		var ports = RSDPortDiscovery.resolvePorts()
		if !ports.contains(49152) { ports.append(49152) }
        var failures: [String] = []
        progress(.openingTunnel)
        for port in ports {
            address.sin_port = in_port_t(port).bigEndian
            let providerError = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    tunnel_create_rppairing(
                        $0,
                        socklen_t(MemoryLayout<sockaddr_in>.stride),
						"AetherLocation",
                        pairingHandle,
                        nil,
                        nil,
                        &adapter,
                        &handshake
                    )
                }
            }
            guard let providerError else { break }
            let failure = "\(deviceIP):\(port) — \(ffiErrorDetail(providerError))"
			Task { @MainActor in
				DebugLogManager.shared.log(
					"Location tunnel attempt failed: \(failure)",
					category: "Spoofing",
					level: .warning
				)
			}
            failures.append(failure)
            idevice_error_free(providerError)
            cleanup()
        }
        guard adapter != nil, handshake != nil else {
            cleanup()
            let detail: String
            if let last = failures.last {
                detail = "Tried ports \(ports.map { String($0) }.joined(separator: ", ")). Last error: \(last)"
            } else {
                detail = "No tunnel handles were returned."
            }
            return .failure(.tunnelCreate(detail))
        }

        if let remoteServerError = remote_server_connect_rsd(adapter, handshake, &remoteServer) {
            let detail = ffiErrorDetail(remoteServerError)
            idevice_error_free(remoteServerError)
            cleanup()
            return .failure(.remoteServer(detail))
        }

        if let simError = location_simulation_new(remoteServer, &locationSimulation) {
            let detail = ffiErrorDetail(simError)
            idevice_error_free(simError)
            cleanup()
            return .failure(.simulationCreate(detail))
        }
        return .success(())
    }

    private func clearLocked(
        pairingPath: String,
        deviceIP: String,
        verifyRemotely: Bool
    ) -> Result<Void, LocationEngineError> {
        var firstFailure: String?
        if let locationSimulation {
            if let error = location_simulation_clear(locationSimulation) {
                firstFailure = ffiErrorDetail(error)
                idevice_error_free(error)
            } else {
                cleanup()
                return .success(())
            }
            cleanup()
        } else if !verifyRemotely {
            return .success(())
        }

        // Freeing the local handle does not clear locationd. Reopen the DVT
        // service and retry rather than treating a missing handle as success.
        let reopened = openSessionLocked(pairingPath: pairingPath, deviceIP: deviceIP, progress: { _ in })
        if case .failure(let error) = reopened {
            let prefix = firstFailure.map { "Initial clear failed: \($0). " } ?? ""
            return .failure(.locationClear(prefix + "Reconnect failed: \(error.localizedDescription)"))
        }
        guard let locationSimulation else {
            cleanup()
            return .failure(.locationClear("Reconnect returned no location simulation handle."))
        }
        let retryError = location_simulation_clear(locationSimulation)
        cleanup()
        if let retryError {
            let detail = ffiErrorDetail(retryError)
            idevice_error_free(retryError)
            return .failure(.locationClear("Retry failed: \(detail)"))
        }
        return .success(())
    }

    private func ffiErrorDetail(_ error: UnsafeMutablePointer<IdeviceFfiError>) -> String {
        let message = error.pointee.message.map { String(cString: $0) } ?? "unknown error"
        return "code \(error.pointee.code), subcode \(error.pointee.sub_code): \(message)"
    }
}
