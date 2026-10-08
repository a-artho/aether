import XCTest
import Zip
@testable import Core

final class RegressionTests: XCTestCase {
	private func fixture(_ name: String) -> URL { Bundle.module.url(forResource: name, withExtension: "ipa", subdirectory: "Fixtures")! }
	private func workspace() throws -> URL {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		addTeardownBlock { try? FileManager.default.removeItem(at: url) }
		return url
	}
	func testFeatherExtractionAcceptsSymlinkAndLargeEntryCount() throws {
		Zip.addCustomFileExtension("ipa")
		for name in ["valid", "dot-prefix", "symlink", "too-many"] {
			let root = try workspace(), output = root.appendingPathComponent("output")
			var progress = 0.0
			try Zip.unzipFile(fixture(name), destination: output, overwrite: true, password: nil) { progress = $0 }
			XCTAssertEqual(progress, 1)
			if name == "too-many" {
				XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.appendingPathComponent("Payload/App.app").path).count, 20_001)
			} else if name == "symlink" {
				// Match Feather/Zip: link entries are imported as ordinary files.
				XCTAssertEqual(try String(contentsOf: output.appendingPathComponent("Payload/link"), encoding: .utf8), "../escaped.txt")
			} else {
				XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("Payload/App.app/Info.plist").path))
			}
		}
	}
	func testInputCloneRemainsUnchangedWhenOriginalChanges() throws {
		let root = try workspace(), input = root.appendingPathComponent("input.ipa"), snapshot = root.appendingPathComponent("snapshot.ipa")
		try FileManager.default.copyItem(at: fixture("valid"), to: input)
		try FileManager.default.copyItemPreferClone(at: input, to: snapshot)
		try Data("changed".utf8).write(to: input)
		Zip.addCustomFileExtension("ipa")
		try Zip.unzipFile(snapshot, destination: root.appendingPathComponent("output"), overwrite: true, password: nil)
		XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("output/Payload/App.app/Info.plist")), Data("<plist/>".utf8))
	}

	func testServerProgressDoesNotCompleteBeforeStarting() {
		var monitor = ServerInstallProgress()
		XCTAssertFalse(monitor.observe(progress: nil))
		XCTAssertFalse(monitor.observe(progress: 0))
		XCTAssertFalse(monitor.hasStarted)
	}
	func testServerProgressCompletesAfterReturningToZero() {
		var monitor = ServerInstallProgress()
		XCTAssertFalse(monitor.observe(progress: 0.7))
		XCTAssertFalse(monitor.observe(progress: 1))
		XCTAssertTrue(monitor.observe(progress: 0))
	}
	func testServerProgressMatchesFeatherWhenProgressBecomesUnavailable() {
		var monitor = ServerInstallProgress()
		XCTAssertFalse(monitor.observe(progress: 0.7))
		XCTAssertTrue(monitor.observe(progress: nil))
	}

}
