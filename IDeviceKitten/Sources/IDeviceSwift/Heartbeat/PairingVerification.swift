import Foundation
import CryptoKit

public enum SavedPairingRecordSource: String {
	case onDevice, imported
}

public enum PairingRecordSelection {
	public static let invalidatedPreference = "invalidated"

	public static func resolve(preference: String?, onDeviceExists: Bool, importedExists: Bool) -> SavedPairingRecordSource? {
		// Preserve other saved records for explicit selection; never silently
		// switch records after the selected identity was rejected by iOS.
		guard preference != invalidatedPreference else { return nil }
		if preference == SavedPairingRecordSource.onDevice.rawValue, onDeviceExists { return .onDevice }
		if preference == SavedPairingRecordSource.imported.rawValue, importedExists { return .imported }
		if onDeviceExists { return .onDevice }
		if importedExists { return .imported }
		return nil
	}
}

/// Identifies the exact saved record used by a connection attempt. Never log its contents.
public struct PairingRecordIdentity: Equatable, Sendable {
	public let fileURL: URL
	public let digest: Data

	public init?(fileURL: URL) {
		guard let data = try? Data(contentsOf: fileURL) else { return nil }
		self.fileURL = fileURL
		self.digest = Data(SHA256.hash(data: data))
	}

	/// Record replacement and deletion are serialized on the caller's main actor.
	@MainActor
	@discardableResult
	public func discardIfUnchanged() throws -> Bool {
		guard PairingRecordIdentity(fileURL: fileURL) == self else { return false }
		try FileManager.default.removeItem(at: fileURL)
		return true
	}
}

public struct DeviceConnectionCheck: Sendable {
	public let isConnected: Bool
	public let error: String?
	public let errorCode: Int32?
	public let errorSubCode: Int32?
	public let apps: [AppInfo]?
	public let isTransientTransportFailure: Bool

	public init(isConnected: Bool, error: String? = nil, errorCode: Int32? = nil, errorSubCode: Int32? = nil, apps: [AppInfo]? = nil, isTransientTransportFailure: Bool = false) {
		self.isConnected = isConnected
		self.error = error
		self.errorCode = errorCode
		self.errorSubCode = errorSubCode
		self.apps = apps
		self.isTransientTransportFailure = !isConnected && (isTransientTransportFailure
			|| errorCode.map { [1, 3, 4, 17, 19, 21, 109].contains($0) } == true)
	}

	/// idevice 0.1.68: InvalidHostID=18; RemotePairing=103, PairVerifyFailed=5.
	/// Retain the older InvalidHostID code for the legacy heartbeat transport.
	public var rejectsPairingRecord: Bool {
		!isConnected && (errorCode == 18 || errorCode == -9 || (errorCode == 103 && errorSubCode == 5))
	}
}

public struct PairingVerificationState: Equatable {
	public enum Status: Equatable {
		case missing, saved, checking, verified, unableToVerify
	}

	public private(set) var record: PairingRecordIdentity?
	public private(set) var status: Status = .missing

	public init() {}

	public mutating func select(_ record: PairingRecordIdentity?) {
		guard self.record != record else { return }
		self.record = record
		status = record == nil ? .missing : .saved
	}

	public mutating func beginChecking(_ record: PairingRecordIdentity) {
		select(record)
		status = .checking
	}

	/// Ignore completions belonging to a file that was replaced during verification.
	public mutating func finishChecking(_ record: PairingRecordIdentity, succeeded: Bool) {
		guard self.record == record else { return }
		status = succeeded ? .verified : .unableToVerify
	}
}
