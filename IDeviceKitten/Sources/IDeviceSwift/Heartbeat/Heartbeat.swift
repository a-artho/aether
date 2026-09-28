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
	private static let pairingMigrationLock = NSLock()
	private static var hasCompletedPairingMigration = false

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

	/// Feather's visible Documents root, shared by both pairing record types.
	static public func pairingDirectoryURL() -> URL {
		migratePairingRecordsToDocumentsIfNeeded()
		return pairingDirectory()
	}

	static public func importedPairingFileURL() -> URL {
		migratePairingRecordsToDocumentsIfNeeded()
		return importedPairingFile()
	}

	/// Returns the imported pairing file path.
	static public func pairingFile() -> String {
		importedPairingFileURL().path
	}

	/// Returns the on-device Remote Pairing record location.
	static public func onDevicePairingFileURL() -> URL {
		migratePairingRecordsToDocumentsIfNeeded()
		return onDevicePairingFile()
	}

	static public func hasOnDevicePairingFile() -> Bool {
		migratePairingRecordsToDocumentsIfNeeded()
		return FileManager.default.fileExists(atPath: onDevicePairingFile().path)
	}

	static public func hasImportedPairingFile() -> Bool {
		migratePairingRecordsToDocumentsIfNeeded()
		return FileManager.default.fileExists(atPath: importedPairingFile().path)
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

	private static func pairingDirectory() -> URL {
		FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
	}

	private static func importedPairingFile() -> URL {
		pairingDirectory().appendingPathComponent("pairingFile.plist")
	}

	private static func onDevicePairingFile() -> URL {
		pairingDirectory().appendingPathComponent("onDeviceRPPairing.plist")
	}

	private static func legacyOnDevicePairingFile() -> URL {
		let applicationSupport = FileManager.default.urls(
			for: .applicationSupportDirectory,
			in: .userDomainMask
		).first!
		return applicationSupport
			.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Feather", isDirectory: true)
			.appendingPathComponent("onDeviceRPPairing.plist")
	}

	/// Moves records written by earlier Feather builds into Documents.
	/// This is safe to run repeatedly and never replaces a current record.
	private static func migratePairingRecordsToDocumentsIfNeeded() {
		pairingMigrationLock.lock()
		defer { pairingMigrationLock.unlock() }
		guard !hasCompletedPairingMigration,
			  UIApplication.shared.isProtectedDataAvailable else {
			return
		}

		let fileManager = FileManager.default
		let source = legacyOnDevicePairingFile()
		let destination = onDevicePairingFile()
		guard fileManager.fileExists(atPath: source.path) else {
			hasCompletedPairingMigration = true
			return
		}
		guard !fileManager.fileExists(atPath: destination.path) else {
			hasCompletedPairingMigration = true
			return
		}

		movePairingRecordIfNeeded(
			from: source,
			to: destination,
			fileManager: fileManager
		)
		hasCompletedPairingMigration = fileManager.fileExists(atPath: destination.path)
	}

	private static func movePairingRecordIfNeeded(
		from source: URL,
		to destination: URL,
		fileManager: FileManager
	) {
		guard source != destination,
			  fileManager.fileExists(atPath: source.path),
			  !fileManager.fileExists(atPath: destination.path) else {
			return
		}

		do {
			try fileManager.moveItem(at: source, to: destination)
		} catch {
			// A copy/remove fallback handles the unlikely case that the two
			// container locations cannot be renamed atomically.
			do {
				try fileManager.copyItem(at: source, to: destination)
				try fileManager.removeItem(at: source)
			} catch {
				try? fileManager.removeItem(at: destination)
			}
		}
	}
}
