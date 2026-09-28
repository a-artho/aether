//
//  SwiftAR.swift
//  SwiftAR
//
//  Created by nekohaxx on 8/18/24.
//

import Foundation

class AR: NSObject {
	private var _data: Data
	
	init(with url: URL) throws {
		self._data = try Data(contentsOf: url, options: [.mappedIfSafe])
		super.init()
	}
	
	func extract() async throws -> [ARFileModel] {
		let magic = Data([0x21, 0x3c, 0x61, 0x72, 0x63, 0x68, 0x3e, 0x0a])
		guard _data.count >= magic.count, _data.prefix(magic.count) == magic else {
			throw ARError.badArchive("Invalid magic")
		}

		var offset = magic.count
		var files: [ARFileModel] = []
		while offset < _data.count {
			try Task.checkCancellation()
			let fileInfo = try _getFileInfo(_data, offset)
			files.append(fileInfo)
			let (nextOffset, overflow) = offset.addingReportingOverflow(60 + fileInfo.size)
			guard !overflow else { throw ARError.badArchive("Invalid entry offset") }
			offset = nextOffset + (fileInfo.size % 2)
		}
		return files
	}
	
	private func _getFileInfo(_ data: Data, _ offset: Int) throws -> ARFileModel {
		guard offset >= 0, offset <= data.count, data.count - offset >= 60 else {
			throw ARError.badArchive("Truncated entry header")
		}
		guard data[offset + 58] == 0x60, data[offset + 59] == 0x0A else {
			throw ARError.badArchive("Invalid entry header")
		}

		let sizeString = try _field(data, range: offset + 48..<offset + 58)
		guard let size = Int(sizeString), size >= 0, size <= data.count - (offset + 60) else {
			throw ARError.badArchive("Invalid size")
		}
		
		let name = try _field(data, range: offset..<offset + 16)
			.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
		guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
			throw ARError.badArchive("Invalid name")
		}

		let timestamp = Double(try _field(data, range: offset + 16..<offset + 28)) ?? 0
		let ownerID = Int(try _field(data, range: offset + 28..<offset + 34)) ?? 0
		let groupID = Int(try _field(data, range: offset + 34..<offset + 40)) ?? 0
		let mode = Int(try _field(data, range: offset + 40..<offset + 48), radix: 8) ?? 0
		
		return ARFileModel(
			name: name,
			modificationDate: Date(timeIntervalSince1970: timestamp),
			ownerId: ownerID,
			groupId: groupID,
			mode: mode,
			size: size,
			content: data[offset+60..<offset+60+size]
		)
	}
	
	private func _field(_ data: Data, range: Range<Int>) throws -> String {
		guard range.lowerBound >= 0, range.upperBound <= data.count,
		      let value = String(data: data[range], encoding: .ascii)
		else {
			throw ARError.badArchive("Invalid header field")
		}
		return value.trimmingCharacters(in: .whitespacesAndNewlines)
	}
}

enum ARError: Error {
	case badArchive(String)
}
