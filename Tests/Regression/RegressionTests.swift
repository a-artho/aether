import XCTest
@testable import Core

final class RegressionTests: XCTestCase {
	private func fixture(_ name: String) -> URL { Bundle.module.url(forResource: name, withExtension: "ipa", subdirectory: "Fixtures")! }
	private func workspace() throws -> URL {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		addTeardownBlock { try? FileManager.default.removeItem(at: url) }
		return url
	}
	func testMaliciousArchivesCannotWriteOutsideOrLeavePartialOutput() throws {
		for name in ["traversal", "backslash", "absolute", "drive", "nested", "symlink", "duplicate", "parent-conflict", "crc", "too-many", "oversize", "truncated", "encrypted-tail", "invalid-local-tail"] {
			let root = try workspace(), destination = root.appendingPathComponent("output")
			let sentinel = root.appendingPathComponent("escaped.txt")
			try Data("unchanged".utf8).write(to: sentinel)
			XCTAssertThrowsError(try SafeIPAArchive.extract(fixture(name), to: destination) { _ in }, name)
			XCTAssertEqual(try Data(contentsOf: sentinel), Data("unchanged".utf8), name)
			XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), name)
		}
	}
	func testValidNestedArchiveAndDotPrefix() throws {
		for name in ["valid", "dot-prefix", "zip64"] {
			let root = try workspace(), output = root.appendingPathComponent("output")
			try SafeIPAArchive.extract(fixture(name), to: output) { _ in }
			XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("Payload/App.app/Info.plist").path))
		}
	}
	func testCaseDistinctResourcesAreAcceptedByInspection() throws {
		XCTAssertEqual(try SafeIPAArchive.inspect(fixture("case-distinct")).entries, 2)
		let root = try workspace(), probe = root.appendingPathComponent("probe")
		try Data().write(to: probe)
		if !FileManager.default.fileExists(atPath: root.appendingPathComponent("PROBE").path) {
			let output = root.appendingPathComponent("output")
			try SafeIPAArchive.extract(fixture("case-distinct"), to: output) { _ in }
			XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("Payload/App.app/File")), Data("a".utf8))
			XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("Payload/App.app/file")), Data("b".utf8))
		}
	}

	func testExistingOutputSymlinkIsRejected() throws {
		let root = try workspace(), elsewhere = root.appendingPathComponent("elsewhere"), output = root.appendingPathComponent("output")
		try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false)
		try FileManager.default.createSymbolicLink(at: output, withDestinationURL: elsewhere)
		XCTAssertThrowsError(try SafeIPAArchive.extract(fixture("valid"), to: output) { _ in })
		XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [])
	}
	func testCancellationCleansPartialExtraction() async throws {
		let root = try workspace(), output = root.appendingPathComponent("output"), input = fixture("valid")
		let worker = Task {
			try SafeIPAArchive.extract(input, to: output) { _ in withUnsafeCurrentTask { $0?.cancel() } }
		}
		do { try await worker.value; XCTFail("Cancellation must stop extraction") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
		XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
	}
	func testInputCloneRemainsUnchangedWhenOriginalChanges() throws {
		let root = try workspace(), input = root.appendingPathComponent("input.ipa"), snapshot = root.appendingPathComponent("snapshot.ipa")
		try FileManager.default.copyItem(at: fixture("valid"), to: input)
		try FileManager.default.copyItemPreferClone(at: input, to: snapshot)
		try Data("changed".utf8).write(to: input)
		XCTAssertEqual(try SafeIPAArchive.inspect(snapshot).entries, 4)
		try SafeIPAArchive.extract(snapshot, to: root.appendingPathComponent("output")) { _ in }
	}

	private func state(_ version: String, at date: Double = 1) -> ServerInstallMonitor.InstalledState {
		.init(installed: true, version: version, registeredAt: Date(timeIntervalSince1970: date))
	}
	func testDisappearingProgressIsNotSuccess() {
		var monitor = ServerInstallMonitor(expectedVersion: "2", previous: state("1"), startedAt: 0)
		XCTAssertEqual(monitor.observe(progress: 0.7, installed: state("1"), now: 1), .waiting)
		XCTAssertEqual(monitor.observe(progress: nil, installed: state("1"), now: 2), .waiting)
		if case .failed = monitor.observe(progress: nil, installed: state("1"), now: 33) {} else { XCTFail("Must fail bounded verification") }
	}
	func testNewVersionAndRegistrationVerifySuccess() {
		var update = ServerInstallMonitor(expectedVersion: "2", previous: state("1"), startedAt: 0)
		_ = update.observe(progress: 0.7, installed: state("1"), now: 1)
		XCTAssertEqual(update.observe(progress: nil, installed: state("2", at: 2), now: 2), .success)
		var reinstall = ServerInstallMonitor(expectedVersion: "1", previous: state("1"), startedAt: 0)
		_ = reinstall.observe(progress: 0.7, installed: state("1"), now: 1)
		XCTAssertEqual(reinstall.observe(progress: nil, installed: state("1"), now: 2), .waiting)
		XCTAssertEqual(reinstall.observe(progress: nil, installed: state("1", at: 2), now: 3), .success)
	}
	func testFastInstallWithoutProgressPulseUsesChangedDeviceEvidence() {
		var monitor = ServerInstallMonitor(expectedVersion: "2", previous: state("1"), startedAt: 0)
		XCTAssertEqual(monitor.observe(progress: nil, installed: state("2", at: 2), now: 1), .success)
		var unchanged = ServerInstallMonitor(expectedVersion: "1", previous: state("1"), startedAt: 0)
		XCTAssertEqual(unchanged.observe(progress: 1, installed: state("1"), now: 1), .waiting)
		if case .failed = unchanged.observe(progress: nil, installed: state("1"), now: 32) {} else { XCTFail("An unchanged copy cannot prove a reinstall") }
	}

	func testNoStartAndEndlessPositiveProgressHaveDeadlines() {
		var monitor = ServerInstallMonitor(expectedVersion: "1", previous: nil, startedAt: 0)
		if case .failed = monitor.observe(progress: nil, installed: nil, now: 120) {} else { XCTFail("No start deadline") }
		var active = ServerInstallMonitor(expectedVersion: "1", previous: nil, startedAt: 0)
		if case .failed = active.observe(progress: 0.5, installed: nil, now: 1800) {} else { XCTFail("No overall deadline") }
	}
	func testCancellationBeforeAndAfterAttachingWorker() async {
		for before in [true, false] {
			let relay = TaskCancellationRelay()
			if before { relay.cancel() }
			let worker = Task { while !Task.isCancelled { await Task.yield() } }
			relay.attach(worker)
			if !before { relay.cancel() }
			await worker.value
			XCTAssertTrue(worker.isCancelled)
		}
	}
}
