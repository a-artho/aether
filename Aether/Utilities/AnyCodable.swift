//
//  AnyCodable.swift
//  Aether
//
//  Created by samara on 27.04.2025.
//

import Foundation

struct AnyCodable: Codable, Sendable {
	private indirect enum Value: Sendable {
		case null, bool(Bool), int(Int), uint(UInt), double(Double), string(String)
		case array([AnyCodable]), dictionary([String: AnyCodable]), unsupported(String)
	}
	private let stored: Value
	var value: Any {
		switch stored {
		case .null: return NSNull()
		case .bool(let v): return v
		case .int(let v): return v
		case .uint(let v): return v
		case .double(let v): return v
		case .string(let v), .unsupported(let v): return v
		case .array(let v): return v.map(\.value)
		case .dictionary(let v): return v.mapValues(\.value)
		}
	}
	init(_ value: Any) {
		switch value {
		case is NSNull: stored = .null
		case let v as Bool: stored = .bool(v)
		case let v as Int: stored = .int(v)
		case let v as UInt: stored = .uint(v)
		case let v as Double: stored = .double(v)
		case let v as String: stored = .string(v)
		case let v as [Any]: stored = .array(v.map(AnyCodable.init))
		case let v as [String: Any]: stored = .dictionary(v.mapValues(AnyCodable.init))
		default: stored = .unsupported(String(describing: value))
		}
	}
	init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()
		
		if container.decodeNil() {
			self.stored = .null
		} else if let bool = try? container.decode(Bool.self) {
			self.stored = .bool(bool)
		} else if let int = try? container.decode(Int.self) {
			self.stored = .int(int)
		} else if let uint = try? container.decode(UInt.self) {
			self.stored = .uint(uint)
		} else if let double = try? container.decode(Double.self) {
			self.stored = .double(double)
		} else if let string = try? container.decode(String.self) {
			self.stored = .string(string)
		} else if let array = try? container.decode([AnyCodable].self) {
			self.stored = .array(array)
		} else if let dictionary = try? container.decode([String: AnyCodable].self) {
			self.stored = .dictionary(dictionary)
		} else {
			throw DecodingError.dataCorruptedError(in: container, debugDescription: "AnyCodable cannot decode value")
		}
	}
	
	func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		
		switch self.stored {
		case .null:
			try container.encodeNil()
		case .bool(let bool):
			try container.encode(bool)
		case .int(let int):
			try container.encode(int)
		case .uint(let uint):
			try container.encode(uint)
		case .double(let double):
			try container.encode(double)
		case .string(let string):
			try container.encode(string)
		case .array(let array):
			try container.encode(array)
		case .dictionary(let dictionary):
			try container.encode(dictionary)
		case .unsupported:
			throw EncodingError.invalidValue(self.value, EncodingError.Context(codingPath: container.codingPath, debugDescription: "AnyCodable cannot encode value"))
		}
	}
}
