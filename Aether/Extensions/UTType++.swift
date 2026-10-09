//
//  UTType+ipa.swift
//  Aether
//
//  Created by samara on 11.04.2025.
//

import UniformTypeIdentifiers

extension UTType {
	static let dylib: UTType = .init(filenameExtension: "dylib")!
	static let deb: UTType = .init(filenameExtension: "deb")!
	static let ipa: UTType = .init(filenameExtension: "ipa")!
	static let tipa: UTType = .init(filenameExtension: "tipa")!
	static let entitlements: UTType = .init(filenameExtension: "entitlements", conformingTo: .data)!
	static let p12: UTType = .init(filenameExtension: "p12", conformingTo: .data)!
	static let mobileProvision: UTType = .init(filenameExtension: "mobileprovision", conformingTo: .data)!
}
