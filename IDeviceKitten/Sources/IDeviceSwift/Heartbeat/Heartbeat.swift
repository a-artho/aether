//
//  Heartbeat.swift
//  Feather
//
//  Created by samara on 23.04.2025.
//

import Foundation
import UIKit.UIApplication
import Combine
import IDevice

// MARK: - Class
// ـ♡ﮩ٨ـ heartbeat ♪₊˚
public class HeartbeatManager {
	public enum PairingRecordSource: String {
		case onDevice
		case imported
	}

	static public let shared = HeartbeatManager()
	private static let pairingRecordSourceKey = "feather.activePairingRecordSource"

	typealias IdevicePairingFile = OpaquePointer
	typealias RpPairingFileHandle = OpaquePointer
	typealias TcpProviderHandle = OpaquePointer
	typealias AdapterHandle = OpaquePointer
	typealias RemoteServerHandle = OpaquePointer
	typealias RsdHandshakeHandle = OpaquePointer
	typealias HeartbeatClientHandle = OpaquePointer

	public var fileManager = FileManager.default
	var provider: TcpProviderHandle?
	public var heartbeatThread: Thread?

	public var sessionId: UInt32? = nil
	public let ipAddress: String = "10.7.0.1"
	public let port: UInt16 = UInt16(LOCKDOWN_PORT)
	public let port_rsd: UInt16 = UInt16(49152)

	public let restartLock = NSLock()
	public var isRestartInProgress = false
	public var restartBackoffTime: TimeInterval = 1.0
	public var restartWorkItem: DispatchWorkItem?
	public var firstRun = false

	let rsdConnectionLock = NSLock()
	var rsdAdapter: AdapterHandle?
	var rsdHandshake: RsdHandshakeHandle?

	public var cancellable: AnyCancellable? // Combine

	// One important note is that if a user gets `InvalidHostID -9` from heartbeat
	// we need to ask them to reimport a fresh pairingfile,
	public init() {
		#if DEBUG
		idevice_init_logger(IdeviceLogLevel.init(3), Disabled, nil)
		#endif

		if #available(iOS 17.4, *) {
		} else {
			// On first start, just be a normal run, on second and onwards
			// we force restart it with a different sessionid
			cancellable = NotificationCenter.default
				.publisher(for: UIApplication.willEnterForegroundNotification)
				.receive(on: DispatchQueue.main)
				.sink { notification in
					let forceRestart = self.firstRun
					self.firstRun = true
					self.start(forceRestart)
				}
		}
	}

	public var isRsd: Bool {
		if #available(iOS 17.4, *) {
			true
		} else {
			false
		}
	}

	/// Returns the legacy/imported pairing file path.
	///
	/// This remains in Documents for compatibility with the existing importer and
	/// desktop tools that write a record directly into Feather's container.
	static public func pairingFile() -> String {
		FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("pairingFile.plist").relativePath
	}

	/// Returns the private location reserved for a record created on the device.
	///
	/// A Remote Pairing record contains the host's long-term private key, so a
	/// self-created record must not be placed in the file-sharing Documents folder.
	static public func onDevicePairingFileURL() -> URL {
		let applicationSupport = FileManager.default.urls(
			for: .applicationSupportDirectory,
			in: .userDomainMask
		).first!
		let directory = applicationSupport.appendingPathComponent(
			Bundle.main.bundleIdentifier ?? "Feather",
			isDirectory: true
		)
		return directory.appendingPathComponent("onDeviceRPPairing.plist")
	}

	static public func hasOnDevicePairingFile() -> Bool {
		FileManager.default.fileExists(atPath: onDevicePairingFileURL().path)
	}

	static public func hasImportedPairingFile() -> Bool {
		FileManager.default.fileExists(atPath: pairingFile())
	}

	/// Returns the selected pairing record, falling back to the only available
	/// record when the previously selected one is no longer on disk.
	static public func activePairingRecordSource() -> PairingRecordSource? {
		let preferredSource = UserDefaults.standard.string(forKey: pairingRecordSourceKey)
			.flatMap(PairingRecordSource.init(rawValue:))

		if preferredSource == .onDevice, hasOnDevicePairingFile() {
			return .onDevice
		}
		if preferredSource == .imported, hasImportedPairingFile() {
			return .imported
		}
		if hasOnDevicePairingFile() {
			return .onDevice
		}
		if hasImportedPairingFile() {
			return .imported
		}
		return nil
	}

	/// The pairing record used by the iDevice transport.
	///
	/// Imported and on-device records are intentionally stored separately. They
	/// use different pairing formats and changing one must not destroy the other.
	static public func activePairingFile() -> String {
		switch activePairingRecordSource() {
		case .onDevice:
			return onDevicePairingFileURL().path
		case .imported, .none:
			return pairingFile()
		}
	}

	static public func hasPairingFile() -> Bool {
		activePairingRecordSource() != nil
	}

	static public func useOnDevicePairingFile() {
		guard hasOnDevicePairingFile() else { return }
		UserDefaults.standard.set(PairingRecordSource.onDevice.rawValue, forKey: pairingRecordSourceKey)
	}

	static public func useImportedPairingFile() {
		guard hasImportedPairingFile() else { return }
		UserDefaults.standard.set(PairingRecordSource.imported.rawValue, forKey: pairingRecordSourceKey)
	}

	static public func removeOnDevicePairingFile() throws {
		let url = onDevicePairingFileURL()
		guard FileManager.default.fileExists(atPath: url.path) else { return }
		try FileManager.default.removeItem(at: url)
		if UserDefaults.standard.string(forKey: pairingRecordSourceKey) == PairingRecordSource.onDevice.rawValue {
			UserDefaults.standard.removeObject(forKey: pairingRecordSourceKey)
		}
	}
}
