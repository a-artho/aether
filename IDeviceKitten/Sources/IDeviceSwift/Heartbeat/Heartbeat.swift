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
// its own lock; current pairing records are read from Documents.
public final class HeartbeatManager: @unchecked Sendable {
	public typealias PairingRecordSource = SavedPairingRecordSource

	static public let shared = HeartbeatManager()
	private static let pairingRecordSourceKey = "aether.activePairingRecordSource"

	typealias IdevicePairingFile = OpaquePointer

	typealias AdapterHandle = OpaquePointer
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
		return importedPairingFile()
	}

	/// Returns the imported pairing file path.
	static public func pairingFile() -> String {
		importedPairingFileURL().path
	}

	/// Returns the on-device Remote Pairing record location.
	static public func onDevicePairingFileURL() -> URL {
		return onDevicePairingFile()
	}

	static public func hasOnDevicePairingFile() -> Bool {
		return FileManager.default.fileExists(atPath: onDevicePairingFile().path)
	}

	static public func hasImportedPairingFile() -> Bool {
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

}
