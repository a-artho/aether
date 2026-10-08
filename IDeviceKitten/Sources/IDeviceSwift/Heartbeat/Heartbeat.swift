//
//  Heartbeat.swift
//  Aether
//
//  Created by samara on 23.04.2025.
//

import Foundation
import IDevice

// MARK: - Class
// ـ♡ﮩ٨ـ heartbeat ♪₊˚
// RSD handles/generation are protected by rsdConnectionLock. The endpoint has
// its own lock; pairing migration is serialized by pairingMigrationLock.
public final class HeartbeatManager: @unchecked Sendable {
	public typealias PairingRecordSource = SavedPairingRecordSource

	static public let shared = HeartbeatManager()
	private static let pairingRecordSourceKey = "aether.activePairingRecordSource"
	private static let pairingMigrationLock = NSLock()
	private static var hasCompletedPairingMigration = false

	typealias IdevicePairingFile = OpaquePointer
	typealias RpPairingFileHandle = OpaquePointer

	typealias AdapterHandle = OpaquePointer
	typealias RemoteServerHandle = OpaquePointer
	typealias RsdHandshakeHandle = OpaquePointer

	public let fileManager = FileManager.default

	private let endpointLock = NSLock()
    private var endpointAddress = "10.7.0.1"
    public var ipAddress: String {
        get { endpointLock.lock(); defer { endpointLock.unlock() }; return endpointAddress }
        set { endpointLock.lock(); defer { endpointLock.unlock() }; endpointAddress = newValue }
    }
	public let port_rsd: UInt16 = UInt16(49152)

	let rsdConnectionLock = NSLock()
	var rsdGeneration: UInt64 = 0
	var serviceConnectionGeneration: UInt64 {
		rsdConnectionLock.lock()
		defer { rsdConnectionLock.unlock() }
		return rsdGeneration
	}
	var rsdAdapter: AdapterHandle?
	var rsdHandshake: RsdHandshakeHandle?
	var lastSuccessfulRSDPort: UInt16?

	// InvalidHostID means the saved pairing identity is no longer accepted.
	public init() {
		#if DEBUG
		idevice_init_logger(IdeviceLogLevel.init(3), Disabled, nil)
		#endif

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
		PairingRecordSelection.resolve(
			preference: UserDefaults.standard.string(forKey: pairingRecordSourceKey),
			onDeviceExists: hasOnDevicePairingFile(),
			importedExists: hasImportedPairingFile()
		)
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

	/// Discard only the record whose authentication was rejected. Calls are made
	/// on the main actor, alongside record import/selection, to avoid replacement races.
	@MainActor
	@discardableResult
	static public func discardRejectedPairingRecord(_ record: PairingRecordIdentity) throws -> Bool {
		guard activePairingRecordSource() != nil,
			PairingRecordIdentity(fileURL: URL(fileURLWithPath: activePairingFile())) == record else { return false }
		guard try record.discardIfUnchanged() else { return false }
		UserDefaults.standard.set(PairingRecordSelection.invalidatedPreference, forKey: pairingRecordSourceKey)
		return true
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
			.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Aether", isDirectory: true)
			.appendingPathComponent("onDeviceRPPairing.plist")
	}

	/// Moves records written by earlier Aether builds into Documents.
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
