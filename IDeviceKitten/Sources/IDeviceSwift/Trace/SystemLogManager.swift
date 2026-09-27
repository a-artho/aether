//
//  SystemLogManager.swift
//  syslog
//
//  Created by samara on 14.05.2025.
//

import UIKit
import IDevice

// MARK: - Class
public class SystemLogManager: NSObject {
	static let shared = SystemLogManager()
	private let _heartbeat = HeartbeatManager.shared

	typealias SyslogClientHandle = OpaquePointer
	typealias OsTraceRelayClientHandle = OpaquePointer
	typealias OsTraceRelayReceiverHandle = OpaquePointer

	private var syslogClient: SyslogClientHandle?
	private var osTraceRelayClient: OsTraceRelayClientHandle?
	private var osTraceReceiverClient: OsTraceRelayReceiverHandle?

	public var isStreaming: Bool = false {
		didSet {
			NotificationCenter.default.post(
				Notification(name: .isStreamingDidChange, object: isStreaming)
			)
		}
	}

	public weak var delegate: SystemLogManagerDelegate?

	private func _connect() async throws {
		guard FileManager.default.fileExists(atPath: HeartbeatManager.pairingFile()) else {
			throw IDeviceConnectionError.pairingFileMissing
		}

		if !self._heartbeat.isRsd {
			let connection = self._heartbeat.checkSocketConnection()
			guard connection.isConnected else {
				throw IDeviceConnectionError.legacyEndpointUnavailable(connection.error)
			}
			guard (self._heartbeat.provider != nil) else {
				throw IDeviceConnectionError.tcpProviderUnavailable
			}
		}
	}

	/// Connects to syslog relay
	public func syslog_relay() async throws {
		try await Task.detached(priority: .utility) {
			try await self._connect()
			defer {
				if let client = self.syslogClient {
					syslog_relay_client_free(client)
					self.syslogClient = nil
				}
				self.isStreaming = false
			}

			if self._heartbeat.isRsd {
				try self._heartbeat.withRSDServiceConnection { adapter, handshake in
					syslog_relay_connect_rsd(adapter, handshake, &self.syslogClient)
				}
			} else {
				if let error = syslog_relay_connect_tcp(self._heartbeat.provider, &self.syslogClient) {
					throw IDeviceSwiftError(error)
				}
			}

			self.isStreaming = true

			while self.isStreaming {
				guard let syslogClient = self.syslogClient else {
					break
				}

				var logLinePointer: UnsafeMutablePointer<CChar>? = nil
				let result = syslog_relay_next(syslogClient, &logLinePointer)

				// This may crash due to accessing an invalid pointer
				// don't know how to fix it yet! If you do know how
				// to fix it, please tell me!!!
				if result == nil, let logLinePointer = logLinePointer {
					if let logLine = String(validatingUTF8: logLinePointer) {
						self.delegate?.activityStream(didRecieveString: logLine)
						idevice_string_free(logLinePointer)
					} else {
						idevice_string_free(logLinePointer)
					}
				} else if let result {
					_ = IDeviceSwiftError(result)
					break
				}
			}

		}.value
	}
	/// Connects to os trace relay, this is the backbone of our app
	public func os_trace_relay() async throws {
		try await Task.detached(priority: .utility) {
			try await self._connect()
			defer {
				if let receiver = self.osTraceReceiverClient {
					os_trace_relay_receiver_free(receiver)
					self.osTraceReceiverClient = nil
				}
				if let client = self.osTraceRelayClient {
					os_trace_relay_free(client)
					self.osTraceRelayClient = nil
				}
				self.isStreaming = false
			}

			if self._heartbeat.isRsd {
				try self._heartbeat.withRSDServiceConnection { adapter, handshake in
					os_trace_relay_connect_rsd(adapter, handshake, &self.osTraceRelayClient)
				}
			} else {
				if let error = os_trace_relay_connect(self._heartbeat.provider, &self.osTraceRelayClient) {
					throw IDeviceSwiftError(error)
				}
			}

			if let error = os_trace_relay_start_trace(
				self.osTraceRelayClient,
				&self.osTraceReceiverClient,
				nil
			) {
				throw IDeviceSwiftError(error)
			}

			self.isStreaming = true

			while self.isStreaming {
				guard let recClient = self.osTraceReceiverClient else {
					break
				}

				var oslogg: UnsafeMutablePointer<OsTraceLog>? = nil
				let result = os_trace_relay_next(recClient, &oslogg)

				if result == nil, let oslogg = oslogg {
					let logCopy = oslogg.pointee
					let model = LogEntry(logCopy)
					self.delegate?.activityStream(didRecieveEntry: model)
					os_trace_relay_free_log(oslogg)
				} else if let result {
					_ = IDeviceSwiftError(result)
					break
				}
			}

		}.value
	}
	/// Stops streaming
	public func stop() {
		isStreaming = false
	}

	deinit {
		stop()
	}
}
