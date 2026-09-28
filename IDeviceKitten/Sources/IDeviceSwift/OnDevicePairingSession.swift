//
//  OnDevicePairingSession.swift
//  IDeviceKit
//
//  Created by Feather.
//

import Darwin
import Foundation
import IDevice
import Network

private final class OnDevicePairingCodeCallbackBox: @unchecked Sendable {
	let handler: @Sendable (String) -> Void

	init(handler: @escaping @Sendable (String) -> Void) {
		self.handler = handler
	}
}

private func onDevicePairingCodeCallback(
	_ pin: UnsafePointer<CChar>?,
	_ context: UnsafeMutableRawPointer?
) {
	guard let pin, let context else { return }
	let callback = Unmanaged<OnDevicePairingCodeCallbackBox>
		.fromOpaque(context)
		.takeUnretainedValue()
	callback.handler(String(cString: pin))
}

public enum OnDevicePairingSessionError: LocalizedError {
	case alreadyRunning
	case unavailable
	case malformedAdvertisement
	case cancelled

	public var errorDescription: String? {
		switch self {
		case .alreadyRunning:
			return "A pairing session is already running."
		case .unavailable:
			return "Could not start the pairing session."
		case .malformedAdvertisement:
			return "Could not prepare the pairing service."
		case .cancelled:
			return "Pairing was cancelled."
		}
	}
}

/// Owns one device-initiated Remote Pairing session.
///
/// iOS discovers pairable hosts through Bonjour, but the native pairing
/// handshake needs the accepted TCP socket. The native library therefore
/// prepares the identity and TXT record, while this wrapper publishes the
/// service with `NetService`, accepts the connection, and hands that socket
/// back to the native host. This matches Locus's pairing lifecycle.
public final class OnDevicePairingSession: @unchecked Sendable {
	private let lock = NSLock()
	private var server: OnDevicePairingSocketServer?
	private var cancellationRequested = false
	private var isRunning = false

	public init() {}

	deinit {
		cancel()
	}

	/// Publishes a single-use pairable host and returns the Remote Pairing record
	/// only after iOS completes its passcode and PIN confirmation.
	public func run(
		displayName: String,
		onCode: @escaping @Sendable (String) -> Void
	) throws -> Data {
		lock.lock()
		guard !isRunning else {
			lock.unlock()
			throw OnDevicePairingSessionError.alreadyRunning
		}
		isRunning = true
		cancellationRequested = false
		lock.unlock()

		defer {
			lock.lock()
			isRunning = false
			server = nil
			lock.unlock()
		}

		let callbackBox = OnDevicePairingCodeCallbackBox(handler: onCode)
		let callbackContext = Unmanaged.passRetained(callbackBox).toOpaque()
		defer {
			Unmanaged<OnDevicePairingCodeCallbackBox>
				.fromOpaque(callbackContext)
				.release()
		}

		let host = try _prepareHost(named: displayName)
		defer { pairable_host_free(host.handle) }

		let server = OnDevicePairingSocketServer(
			serviceIdentifier: host.serviceIdentifier,
			txtRecord: host.txtRecord
		)
		lock.lock()
		self.server = server
		let shouldCancel = cancellationRequested
		lock.unlock()
		if shouldCancel {
			server.cancel()
			throw OnDevicePairingSessionError.cancelled
		}

		defer { server.cancel() }
		try server.start()
		let connection = try server.acceptConnection()

		lock.lock()
		let wasCancelled = cancellationRequested
		lock.unlock()
		if wasCancelled {
			throw OnDevicePairingSessionError.cancelled
		}

		var pairingFile: OpaquePointer?
		let pairingError = pairable_host_accept_fd(
			host.handle,
			connection,
			onDevicePairingCodeCallback,
			callbackContext,
			nil,
			&pairingFile
		)

		if let pairingError {
			throw IDeviceSwiftError(pairingError)
		}

		// `pairable_host_accept_fd` returns as soon as it writes Pair-Setup M6;
		// iOS still has to receive and commit that final response. Keep the
		// original socket and the public relay alive briefly instead of tearing
		// them down immediately on the host-side return.
		try server.waitForDeviceToFinishPairing()

		guard let pairingFile else {
			throw OnDevicePairingSessionError.unavailable
		}
		defer { rp_pairing_file_free(pairingFile) }

		var serializedRecord: UnsafeMutablePointer<UInt8>?
		var serializedRecordLength: UInt = 0
		if let serializationError = rp_pairing_file_to_bytes(
			pairingFile,
			&serializedRecord,
			&serializedRecordLength
		) {
			throw IDeviceSwiftError(serializationError)
		}

		guard let serializedRecord, serializedRecordLength > 0 else {
			throw OnDevicePairingSessionError.unavailable
		}
		defer { idevice_data_free(serializedRecord, serializedRecordLength) }

		return Data(bytes: serializedRecord, count: Int(serializedRecordLength))
	}

	/// Closes the Bonjour listener and active pairing socket, unblocking either
	/// the pre-handshake wait or a pairing handshake in progress.
	public func cancel() {
		lock.lock()
		cancellationRequested = true
		let server = self.server
		lock.unlock()

		server?.cancel()
	}

	private func _prepareHost(named displayName: String) throws -> PreparedPairableHost {
		var hostHandle: OpaquePointer?
		var serviceIdentifier: UnsafeMutablePointer<CChar>?
		var txtData: UnsafeMutablePointer<UInt8>?
		var txtLength: UInt = 0

		let preparationError = displayName.withCString { name in
			"Mac17,7".withCString { model in
				pairable_host_prepare(
					name,
					model,
					true,
					&hostHandle,
					&serviceIdentifier,
					&txtData,
					&txtLength,
					nil
				)
			}
		}

		if let preparationError {
			throw IDeviceSwiftError(preparationError)
		}

		guard let hostHandle, let serviceIdentifier, let txtData, txtLength > 0 else {
			if let hostHandle {
				pairable_host_free(hostHandle)
			}
			if let serviceIdentifier {
				idevice_string_free(serviceIdentifier)
			}
			if let txtData {
				idevice_data_free(txtData, txtLength)
			}
			throw OnDevicePairingSessionError.unavailable
		}
		defer {
			idevice_string_free(serviceIdentifier)
			idevice_data_free(txtData, txtLength)
		}

		let rawTXT = Data(bytes: txtData, count: Int(txtLength))
		let txtRecord: [String: Data]
		do {
			txtRecord = try Self._decodeTXTRecord(rawTXT)
		} catch {
			pairable_host_free(hostHandle)
			throw error
		}
		return PreparedPairableHost(
			handle: hostHandle,
			serviceIdentifier: String(cString: serviceIdentifier),
			txtRecord: txtRecord
		)
	}

	private static func _decodeTXTRecord(_ data: Data) throws -> [String: Data] {
		let propertyList = try PropertyListSerialization.propertyList(
			from: data,
			options: [],
			format: nil
		)
		guard let values = propertyList as? [String: Any] else {
			throw OnDevicePairingSessionError.malformedAdvertisement
		}

		var record: [String: Data] = [:]
		for (key, value) in values {
			switch value {
			case let data as Data:
				record[key] = data
			case let string as String:
				record[key] = Data(string.utf8)
			case let number as NSNumber:
				record[key] = Data(number.stringValue.utf8)
			default:
				throw OnDevicePairingSessionError.malformedAdvertisement
			}
		}

		guard !record.isEmpty else {
			throw OnDevicePairingSessionError.malformedAdvertisement
		}
		return record
	}
}

private struct PreparedPairableHost {
	let handle: OpaquePointer
	let serviceIdentifier: String
	let txtRecord: [String: Data]
}

/// Owns the pairable-host transport.
///
/// Settings discovers the public `NWListener` through Bonjour. Its connection
/// is relayed to a private loopback socket, whose descriptor can safely be
/// passed to `pairable_host_accept_fd`. This keeps Network.framework in charge
/// of the app-facing listener while the native pairing host owns the handshake.
private final class OnDevicePairingSocketServer: @unchecked Sendable {
	private let lock = NSLock()
	private let serviceIdentifier: String
	private let txtRecord: [String: Data]
	private let networkQueue = DispatchQueue(label: "feather.pairable-host.relay")
	private var listener = Int32(-1)
	private var connection = Int32(-1)
	private var relayListener: NWListener?
	private var activeRelay: OnDevicePairingRelay?
	private var cancellationRequested = false
	private var publicationError: String?
	private var receivedDeviceConnection = false

	init(serviceIdentifier: String, txtRecord: [String: Data]) {
		self.serviceIdentifier = serviceIdentifier
		self.txtRecord = txtRecord
	}

	func start() throws {
		let descriptor = try _makeListener()
		let port = try _port(for: descriptor)

		lock.lock()
		if cancellationRequested {
			lock.unlock()
			_close(descriptor)
			throw OnDevicePairingSessionError.cancelled
		}
		listener = descriptor
		lock.unlock()

		do {
			let parameters = NWParameters.tcp
			parameters.allowLocalEndpointReuse = true
			parameters.includePeerToPeer = true

			let relayListener = try NWListener(using: parameters)
			relayListener.service = NWListener.Service(
				name: serviceIdentifier,
				type: "_remotepairing-pairable-host._tcp",
				domain: "local",
				txtRecord: NetService.data(fromTXTRecord: txtRecord)
			)
			relayListener.stateUpdateHandler = { [weak self, weak relayListener] state in
				guard let self, let relayListener else { return }
				self._handleListenerState(state, from: relayListener)
			}
			relayListener.newConnectionHandler = { [weak self, weak relayListener] inbound in
				guard let self, let relayListener else {
					inbound.cancel()
					return
				}
				self._relay(inbound, from: relayListener, toLoopbackPort: port)
			}

			lock.lock()
			guard !cancellationRequested else {
				lock.unlock()
				relayListener.cancel()
				throw OnDevicePairingSessionError.cancelled
			}
			self.relayListener = relayListener
			lock.unlock()
			relayListener.start(queue: networkQueue)
		} catch {
			cancel()
			throw error
		}

		lock.lock()
		let wasCancelled = cancellationRequested
		lock.unlock()
		if wasCancelled {
			cancel()
			throw OnDevicePairingSessionError.cancelled
		}
	}

	func acceptConnection() throws -> Int32 {
		while true {
			lock.lock()
			let descriptor = listener
			let wasCancelled = cancellationRequested
			let publicationError = self.publicationError
			lock.unlock()

			if wasCancelled {
				throw OnDevicePairingSessionError.cancelled
			}
			if let publicationError {
				throw IDeviceSwiftError(message: publicationError)
			}
			guard descriptor >= 0 else {
				throw OnDevicePairingSessionError.unavailable
			}

			var address = sockaddr_storage()
			var addressLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
			let accepted = withUnsafeMutablePointer(to: &address) { pointer in
				pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
					Darwin.accept(descriptor, $0, &addressLength)
				}
			}
			if accepted >= 0 {
				lock.lock()
				if cancellationRequested {
					lock.unlock()
					_close(accepted)
					throw OnDevicePairingSessionError.cancelled
				}
				connection = accepted
				listener = -1
				lock.unlock()
				_close(descriptor)
				return accepted
			}

			if errno == EINTR {
				continue
			}
			lock.lock()
			let error = cancellationRequested ? nil : publicationError
			lock.unlock()
			if let error {
				throw IDeviceSwiftError(message: error)
			}
			throw OnDevicePairingSessionError.cancelled
		}
	}


	/// The native host considers Pair-Setup complete immediately after writing
	/// M6. iOS commits the record just after that write, so closing the relay at
	/// this point invalidates the device's control channel. Wait for iOS to end
	/// the connection or give the final response a small, bounded grace window.
	func waitForDeviceToFinishPairing() throws {
		lock.lock()
		let relay = activeRelay
		let wasCancelled = cancellationRequested
		lock.unlock()

		if wasCancelled {
			throw OnDevicePairingSessionError.cancelled
		}
		guard let relay else {
			throw OnDevicePairingSessionError.unavailable
		}

		relay.waitForDeviceToClose(timeout: 2)

		lock.lock()
		let cancelledAfterWait = cancellationRequested
		lock.unlock()
		if cancelledAfterWait {
			throw OnDevicePairingSessionError.cancelled
		}
	}

	func cancel() {
		lock.lock()
		cancellationRequested = true
		let listener = self.listener
		let connection = self.connection
		let relayListener = self.relayListener
		let activeRelay = self.activeRelay
		self.listener = -1
		self.connection = -1
		self.relayListener = nil
		self.activeRelay = nil
		lock.unlock()

		_close(listener)
		_close(connection)
		activeRelay?.cancel()
		relayListener?.cancel()
	}

	private func _handleListenerState(_ state: NWListener.State, from relayListener: NWListener) {
		guard case .failed(let error) = state else { return }

		lock.lock()
		guard self.relayListener === relayListener, !cancellationRequested else {
			lock.unlock()
			return
		}
		publicationError = "Could not advertise Feather for pairing (\(error.localizedDescription))."
		let listener = self.listener
		self.listener = -1
		self.relayListener = nil
		lock.unlock()
		_close(listener)
		relayListener.cancel()
	}

	private func _relay(
		_ inbound: NWConnection,
		from relayListener: NWListener,
		toLoopbackPort port: UInt16
	) {
		lock.lock()
		guard self.relayListener === relayListener,
			!cancellationRequested,
			!receivedDeviceConnection,
			let loopbackPort = NWEndpoint.Port(rawValue: port)
		else {
			lock.unlock()
			inbound.cancel()
			return
		}
		receivedDeviceConnection = true

		let outbound = NWConnection(
			host: NWEndpoint.Host("127.0.0.1"),
			port: loopbackPort,
			using: .tcp
		)
		let relay = OnDevicePairingRelay(inbound: inbound, outbound: outbound)
		activeRelay = relay
		lock.unlock()

		relay.start(on: networkQueue)
	}

	private func _makeListener() throws -> Int32 {
		let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
		guard descriptor >= 0 else {
			throw OnDevicePairingSessionError.unavailable
		}

		var value: Int32 = 1
		guard setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &value, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
			_close(descriptor)
			throw OnDevicePairingSessionError.unavailable
		}
		var address = sockaddr_in()
		address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
		address.sin_family = sa_family_t(AF_INET)
		address.sin_port = in_port_t(0).bigEndian
		guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
			_close(descriptor)
			throw OnDevicePairingSessionError.unavailable
		}
		let didBind = withUnsafePointer(to: &address) { pointer in
			pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
			}
		}
		guard didBind == 0, Darwin.listen(descriptor, SOMAXCONN) == 0 else {
			_close(descriptor)
			throw OnDevicePairingSessionError.unavailable
		}
		return descriptor
	}

	private func _port(for descriptor: Int32) throws -> UInt16 {
		var address = sockaddr_in()
		var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
		let result = withUnsafeMutablePointer(to: &address) { pointer in
			pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				getsockname(descriptor, $0, &addressLength)
			}
		}
		guard result == 0 else {
			throw OnDevicePairingSessionError.unavailable
		}
		return UInt16(bigEndian: address.sin_port)
	}

	private func _close(_ descriptor: Int32) {
		guard descriptor >= 0 else { return }
		Darwin.shutdown(descriptor, SHUT_RDWR)
		Darwin.close(descriptor)
	}
}

/// Bidirectionally forwards Settings' Network.framework connection to the
/// loopback socket supplied to the native pairing host.
private final class OnDevicePairingRelay: @unchecked Sendable {
	private let inbound: NWConnection
	private let outbound: NWConnection
	private let lock = NSLock()
	private let deviceClosed = DispatchSemaphore(value: 0)
	private var isCancelled = false
	private var hasDeviceClosed = false

	init(inbound: NWConnection, outbound: NWConnection) {
		self.inbound = inbound
		self.outbound = outbound
	}

	func start(on queue: DispatchQueue) {
		inbound.stateUpdateHandler = { [weak self] state in
			switch state {
			case .failed, .cancelled:
				self?._noteDeviceClosed()
				self?.cancel()
			default:
				break
			}
		}
		outbound.stateUpdateHandler = { [weak self] state in
			guard let self else { return }
			switch state {
			case .ready:
				self._pump(from: self.inbound, to: self.outbound)
				self._pump(from: self.outbound, to: self.inbound)
			case .failed, .cancelled:
				self.cancel()
			default:
				break
			}
		}
		inbound.start(queue: queue)
		outbound.start(queue: queue)
	}

	func waitForDeviceToClose(timeout: TimeInterval) {
		lock.lock()
		let alreadyClosed = hasDeviceClosed
		lock.unlock()
		guard !alreadyClosed else { return }
		_ = deviceClosed.wait(timeout: .now() + timeout)
	}

	func cancel() {
		lock.lock()
		guard !isCancelled else {
			lock.unlock()
			return
		}
		isCancelled = true
		lock.unlock()
		inbound.cancel()
		outbound.cancel()
	}

	private func _noteDeviceClosed() {
		lock.lock()
		guard !hasDeviceClosed else {
			lock.unlock()
			return
		}
		hasDeviceClosed = true
		lock.unlock()
		deviceClosed.signal()
	}

	private func _pump(from source: NWConnection, to destination: NWConnection) {
		source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
			guard let self else { return }
			if error != nil {
				self.cancel()
				return
			}
			if let data, !data.isEmpty {
				destination.send(content: data, completion: .contentProcessed { [weak self] sendError in
					guard let self else { return }
					if sendError != nil || isComplete {
						self.cancel()
					} else {
						self._pump(from: source, to: destination)
					}
				})
			} else if isComplete {
				self.cancel()
			} else {
				self._pump(from: source, to: destination)
			}
		}
	}
}
