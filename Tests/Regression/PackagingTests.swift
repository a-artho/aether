import Foundation
import XCTest
import ZIPFoundation
@testable import Core

final class PackagingTests: XCTestCase {
    private var root: URL!
    private var payload: URL!
    private var file: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        payload = root.appendingPathComponent("Payload")
        let app = payload.appendingPathComponent("Test.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Empty"), withIntermediateDirectories: true)
        file = app.appendingPathComponent("binary")
        try Data((0..<600000).map { UInt8($0 % 251) }).write(to: file)
        try FileManager.default.createSymbolicLink(atPath: app.appendingPathComponent("link").path, withDestinationPath: "binary")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func output(_ name: String = UUID().uuidString) -> URL { root.appendingPathComponent(name + ".ipa") }
    private func assertArchive(_ url: URL) throws {
        let archive = try Archive(url: url, accessMode: .read)
        let entry = try XCTUnwrap(archive["Payload/Test.app/binary"])
        var actual = Data()
        _ = try archive.extract(entry) { actual.append($0) }
        XCTAssertEqual(actual, try Data(contentsOf: file))
        XCTAssertNotNil(archive["Payload/Test.app/Empty/"])
        let link = try XCTUnwrap(archive["Payload/Test.app/link"])
        XCTAssertEqual(link.type, .symlink)
        var target = Data()
        _ = try archive.extract(link) { target.append($0) }
        XCTAssertEqual(String(data: target, encoding: .utf8), "binary")
    }
    func testAllCompressionSettingsPreserveFilesDirectoriesAndSymlinks() throws {
        for level: Int32 in [0, 1, -1, 9] {
            let destination = output()
            var progress = [Double]()
            try BundlePackageWriter.write(BundlePackageWriter.entries(at: payload), to: destination, compression: level) { progress.append($0) }
            try assertArchive(destination)
            XCTAssertEqual(progress.last, 1)
            XCTAssertEqual(progress, progress.sorted())
        }
    }
    func testMissingDestinationParentIsReportedBeforeSuccess() throws {
        let destination = root.appendingPathComponent("missing/archive.ipa")
        var completed = false
        XCTAssertThrowsError(try BundlePackageWriter.write(BundlePackageWriter.entries(at: payload), to: destination, compression: 1) { completed = $0 == 1 })
        XCTAssertFalse(completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
    func testCancellationDuringAFileRemovesPartialArchive() throws {
        let destination = output()
        var cancel = false
        let check = { if cancel { throw CancellationError() } }
        XCTAssertThrowsError(try BundlePackageWriter.write(BundlePackageWriter.entries(at: payload), to: destination, compression: 1, check: check) { if $0 > 0 { cancel = true } }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
    func testChangedSourceIsRejectedAndPartialArchiveRemoved() throws {
        let entries = try BundlePackageWriter.entries(at: payload)
        try Data("changed".utf8).write(to: file)
        let destination = output()
        XCTAssertThrowsError(try BundlePackageWriter.write(entries, to: destination, compression: 1) { _ in })
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}
