//
//  UTType+plist.swift
//  Aether
//
//  Created by samara on 20.04.2025.
//


import UniformTypeIdentifiers

extension UTType {
	public static let plist = UTType(filenameExtension: "plist", conformingTo: .data)!
	public static let mobiledevicepairing = UTType(filenameExtension: "mobiledevicepairing", conformingTo: .data)!
}
