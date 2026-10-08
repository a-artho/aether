//
//  Logger++.swift
//  Aether
//
//  Created by samara on 24.05.2025.
//

import OSLog

extension Logger {
	private static let subsystem = Bundle.main.bundleIdentifier ?? "Aether"
	static let signing = Logger(subsystem: subsystem, category: "Signing")
	static let misc = Logger(subsystem: subsystem, category: "Misc")
}
