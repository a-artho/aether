import Foundation
@testable import IDeviceSwift
import XCTest

final class PairingVerificationTests: XCTestCase {
	func testOnlyAuthenticationRejectionInvalidatesRecord() {
		for code: Int32 in [18, -9] {
			XCTAssertTrue(DeviceConnectionCheck(isConnected: false, errorCode: code).rejectsPairingRecord)
		}
		XCTAssertTrue(DeviceConnectionCheck(isConnected: false, errorCode: 103, errorSubCode: 5).rejectsPairingRecord)
		for code: Int32 in [1, 5, 13, 16, 20, 21, 109] {
			XCTAssertFalse(DeviceConnectionCheck(isConnected: false, errorCode: code).rejectsPairingRecord)
		}
		for subcode: Int32 in [0, 1, 2, 3, 4, 6, 7] {
			XCTAssertFalse(DeviceConnectionCheck(isConnected: false, errorCode: 103, errorSubCode: subcode).rejectsPairingRecord)
		}
		XCTAssertFalse(DeviceConnectionCheck(isConnected: true, errorCode: 103, errorSubCode: 5).rejectsPairingRecord)
		XCTAssertFalse(DeviceConnectionCheck(isConnected: false, error: "Connection reset by peer").rejectsPairingRecord)
	}

	func testSavedFileIsNotVerifiedAndTransportFailureRetainsIt() throws {
		let file = try makeRecord()
		defer { try? FileManager.default.removeItem(at: file) }
		let record = try XCTUnwrap(PairingRecordIdentity(fileURL: file))
		var state = PairingVerificationState()
		state.select(record)
		XCTAssertEqual(state.status, .saved)
		state.beginChecking(record)
		XCTAssertEqual(state.status, .checking)
		state.finishChecking(record, succeeded: false)
		XCTAssertEqual(state.status, .unableToVerify)
		XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
		state.finishChecking(record, succeeded: true)
		XCTAssertEqual(state.status, .verified)
		var relaunchedState = PairingVerificationState()
		relaunchedState.select(record)
		XCTAssertEqual(relaunchedState.status, .saved)
	}

	func testReplacedFileCannotBeVerifiedByAnOldAttempt() throws {
		let file = try makeRecord()
		defer { try? FileManager.default.removeItem(at: file) }
		let old = try XCTUnwrap(PairingRecordIdentity(fileURL: file))
		var state = PairingVerificationState()
		state.beginChecking(old)
		try Data("replacement test record".utf8).write(to: file, options: .atomic)
		let replacement = try XCTUnwrap(PairingRecordIdentity(fileURL: file))
		state.select(replacement)
		state.finishChecking(old, succeeded: true)
		XCTAssertEqual(state.status, .saved)
		XCTAssertEqual(state.record, replacement)
	}

	@MainActor
	func testDiscardRequiresExactUnchangedFile() async throws {
		let file = try makeRecord()
		defer { try? FileManager.default.removeItem(at: file) }
		let old = try XCTUnwrap(PairingRecordIdentity(fileURL: file))
		try Data("replacement test record".utf8).write(to: file, options: .atomic)
		XCTAssertFalse(try old.discardIfUnchanged())
		let replacement = try XCTUnwrap(PairingRecordIdentity(fileURL: file))
		XCTAssertTrue(try replacement.discardIfUnchanged())
		XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
		var state = PairingVerificationState()
		state.select(replacement)
		state.select(nil)
		XCTAssertEqual(state.status, .missing)
	}

	func testRejectionDoesNotSilentlyActivateAnotherSavedRecord() {
		let invalidated = PairingRecordSelection.invalidatedPreference
		for onDeviceExists in [false, true] {
			for importedExists in [false, true] {
				XCTAssertNil(PairingRecordSelection.resolve(preference: invalidated, onDeviceExists: onDeviceExists, importedExists: importedExists))
			}
		}
		XCTAssertEqual(PairingRecordSelection.resolve(preference: "imported", onDeviceExists: true, importedExists: true), .imported)
		XCTAssertEqual(PairingRecordSelection.resolve(preference: "onDevice", onDeviceExists: true, importedExists: true), .onDevice)
		XCTAssertEqual(PairingRecordSelection.resolve(preference: nil, onDeviceExists: false, importedExists: true), .imported)
		XCTAssertNil(PairingRecordSelection.resolve(preference: nil, onDeviceExists: false, importedExists: false))
	}

	private func makeRecord() throws -> URL {
		let file = FileManager.default.temporaryDirectory.appendingPathComponent("pairing-verification-test-\(UUID().uuidString)")
		try Data("synthetic test record".utf8).write(to: file, options: .atomic)
		return file
	}
}
