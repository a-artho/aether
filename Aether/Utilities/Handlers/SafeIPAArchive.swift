import Foundation
import ZIPFoundation

/// A private input snapshot and a fresh output directory are required. The same
/// parser supplies both the validated names and the bytes we subsequently read.
enum SafeIPAArchive {
	static let maximumEntries = 20_000
	static let maximumBytes: UInt64 = 16 * 1024 * 1024 * 1024
	struct Inspection { let entries: Int; let bytes: UInt64 }

	static func inspect(_ source: URL) throws -> Inspection {
		let count = try declaredEntryCount(source)
		let archive = try Archive(url: source, accessMode: .read)
		return try validatedEntries(archive, declaredCount: count)
	}

	static func extract(_ source: URL, to root: URL, progress: (Double) -> Void) throws {
		let count = try declaredEntryCount(source)
		let archive = try Archive(url: source, accessMode: .read)
		let inspection = try validatedEntries(archive, declaredCount: count)
		let manager = FileManager.default
		guard !manager.fileExists(atPath: root.path) else { throw UnsafeArchive("The extraction directory already exists.") }
		try manager.createDirectory(at: root, withIntermediateDirectories: false)
		let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
		var totalWritten: UInt64 = 0
		let declaredBytes = inspection.bytes
		var extractedEntries = 0
		do {
			for entry in archive {
				extractedEntries += 1
				try Task.checkCancellation()
				var destination = root
				for component in entry.path.split(separator: "/").filter({ $0 != "." }).map(String.init) { destination.appendPathComponent(component) }
				guard destination.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(resolvedRoot + "/") else {
					throw UnsafeArchive("An archive entry escapes its extraction directory.")
				}
				if entry.type == .directory {
					try manager.createDirectory(at: destination, withIntermediateDirectories: true)
					continue
				}
				try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
				// No archive link entries are permitted, and each file must be new.
				guard !manager.fileExists(atPath: destination.path), manager.createFile(atPath: destination.path, contents: nil) else {
					throw UnsafeArchive("An archive entry conflicts with another file.")
				}
				let output = try FileHandle(forWritingTo: destination)
				defer { try? output.close() }
				var written: UInt64 = 0
				let crc = try archive.extract(entry, bufferSize: 256 * 1024) { chunk in
					try Task.checkCancellation()
					let count = UInt64(chunk.count)
					guard count <= entry.uncompressedSize - written,
						count <= maximumBytes - totalWritten else {
						throw UnsafeArchive("The archive expands beyond its declared size.")
					}
					try output.write(contentsOf: chunk)
					written += count
					totalWritten += count
					progress(declaredBytes == 0 ? 0 : Double(totalWritten) / Double(declaredBytes))
				}
				guard written == entry.uncompressedSize, crc == entry.checksum else {
					throw UnsafeArchive("An archive entry is incomplete or has an invalid checksum.")
				}
				// Preserve executable bits for app/framework binaries, without special modes.
				let permissions = (entry.fileAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
				try manager.setAttributes([.posixPermissions: permissions & 0o777], ofItemAtPath: destination.path)
			}
			guard extractedEntries == inspection.entries else { throw UnsafeArchive("The archive became unreadable during extraction.") }
			progress(1)
		} catch {
			try? manager.removeItem(at: root)
			throw error
		}
	}

	private static func validatedEntries(_ archive: Archive, declaredCount: Int) throws -> Inspection {
		var entries = 0
		var pathBytes = 0
		var total: UInt64 = 0
		var paths: [String: Entry.EntryType] = [:]
		for entry in archive {
			try Task.checkCancellation()
			guard entries < maximumEntries, entry.type != .symlink else {
				throw UnsafeArchive("The archive contains too many entries or a symbolic link.")
			}
			let path = entry.path
			let byteCount = path.utf8.count
			guard byteCount <= 4096, byteCount <= 32 * 1024 * 1024 - pathBytes else {
				throw UnsafeArchive("The archive contains oversized file paths.")
			}
			pathBytes += byteCount
			guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"),
				!path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
				throw UnsafeArchive("The archive contains an unsafe file path.")
			}
			let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
			let trimmed = components.filter { !$0.isEmpty && $0 != "." }
			guard !trimmed.isEmpty, !components.contains("..") else {
				throw UnsafeArchive("The archive contains an unsafe file path.")
			}
			let key = trimmed.joined(separator: "/").precomposedStringWithCanonicalMapping
			if let existing = paths[key], existing != .directory || entry.type != .directory {
				throw UnsafeArchive("The archive contains duplicate or conflicting paths.")
			}
			paths[key] = entry.type
			guard entry.uncompressedSize <= maximumBytes - total else { throw UnsafeArchive("The archive expands to an unsafe size.") }
			total += entry.uncompressedSize
			entries += 1
		}
		// Detect file/parent conflicts independently of archive order.
		for key in paths.keys {
			var parent = (key as NSString).deletingLastPathComponent
			while !parent.isEmpty && parent != "." {
				if paths[parent] == .file { throw UnsafeArchive("An archive file is used as a directory.") }
				parent = (parent as NSString).deletingLastPathComponent
			}
		}
		guard entries > 0, entries == declaredCount else {
			throw UnsafeArchive("The archive is empty, encrypted, or contains unreadable entries.")
		}
		return Inspection(entries: entries, bytes: total)
	}

	/// ZIPFoundation's iterator ends silently on an unreadable entry. Check only
	/// the declared count here; names and payload offsets always come from its
	/// parser. This bounded footer read does not authorize any destination path.
	private static func declaredEntryCount(_ source: URL) throws -> Int {
		let file = try FileHandle(forReadingFrom: source)
		defer { try? file.close() }
		let length = try file.seekToEnd()
		let tailSize = min(length, UInt64(65_535 + 22 + 76))
		guard tailSize >= 22 else { throw UnsafeArchive("The archive footer is missing.") }
		try file.seek(toOffset: length - tailSize)
		let bytes = [UInt8](try file.read(upToCount: Int(tailSize)) ?? Data())
		guard bytes.count == Int(tailSize) else { throw UnsafeArchive("The archive footer is incomplete.") }
		func value(_ offset: Int, _ width: Int) -> UInt64 {
			bytes[offset..<(offset + width)].enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << ($1.offset * 8)) }
		}
		// Match the library's first reverse signature, rather than selecting a
		// different footer hidden in a comment or a self-extracting prefix.
		guard let end = stride(from: bytes.count - 22, through: 0, by: -1).first(where: { value($0, 4) == 0x06054b50 }),
			end + 22 + Int(value(end + 20, 2)) <= bytes.count,
			value(end + 4, 2) == 0, value(end + 6, 2) == 0 else {
			throw UnsafeArchive("The archive footer is invalid or uses multiple disks.")
		}
		var count = value(end + 10, 2)
		guard value(end + 8, 2) == count else { throw UnsafeArchive("The archive entry counts disagree.") }
		if end >= 76, value(end - 20, 4) == 0x07064b50 {
			let record = end - 76
			guard value(record, 4) == 0x06064b50, value(record + 14, 2) >= 45,
				value(record + 16, 4) == 0, value(record + 20, 4) == 0,
				value(end - 16, 4) == 0, value(end - 4, 4) == 1 else {
				throw UnsafeArchive("The ZIP64 archive footer is invalid.")
			}
			count = value(record + 32, 8)
			guard value(record + 24, 8) == count else { throw UnsafeArchive("The archive entry counts disagree.") }
		}
		guard count > 0, count <= maximumEntries else { throw UnsafeArchive("The archive contains an unsafe number of entries.") }
		return Int(count)
	}

	struct UnsafeArchive: LocalizedError {
		let message: String
		init(_ message: String) { self.message = message }
		var errorDescription: String? { message }
	}
}
