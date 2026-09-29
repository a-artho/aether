//
//  DebugLogManager.swift
//  Feather
//
//  Created by samara on 29.09.2026.
//

import Foundation
import OSLog
import SwiftUI
import UIKit

// MARK: - DebugLogItem

public struct DebugLogItem: Identifiable, Hashable {
	public enum Source: String, Hashable {
		case diagnostics = "Diagnostics"
		case appActivity = "App Activity"
	}

	public enum Level: String, CaseIterable, Codable {
		case debug = "Debug"
		case info = "Info"
		case notice = "Notice"
		case warning = "Warning"
		case error = "Error"
		case fault = "Fault"
		case unknown = "Unknown"

		public init(from osLogLevel: OSLogEntryLog.Level) {
			switch osLogLevel {
			case .debug: self = .debug
			case .info: self = .info
			case .notice: self = .notice
			case .error: self = .error
			case .fault: self = .fault
			case .undefined: self = .unknown
			@unknown default: self = .unknown
			}
		}

		public var color: Color {
			switch self {
			case .fault, .error: return .red
			case .warning: return .orange
			case .notice: return .teal
			case .info: return .blue
			case .debug: return .purple
			case .unknown: return .secondary
			}
		}

		public var systemImage: String {
			switch self {
			case .fault: return "xmark.octagon.fill"
			case .error: return "exclamationmark.octagon.fill"
			case .warning: return "exclamationmark.triangle.fill"
			case .notice: return "bell.fill"
			case .info: return "info.circle.fill"
			case .debug: return "ant.fill"
			case .unknown: return "circle.fill"
			}
		}

		public var shortName: String {
			switch self {
			case .fault: return "FAULT"
			case .error: return "ERROR"
			case .warning: return "WARN"
			case .notice: return "NOTE"
			case .info: return "INFO"
			case .debug: return "DEBUG"
			case .unknown: return "LOG"
			}
		}
	}

	public let id: UUID
	public let date: Date
	public let subsystem: String
	public let category: String
	public let level: Level
	public let message: String
	public let source: Source

	public init(
		id: UUID = UUID(),
		date: Date = Date(),
		subsystem: String = Bundle.main.bundleIdentifier ?? "Feather",
		category: String = "App",
		level: Level = .info,
		source: Source = .diagnostics,
		message: String
	) {
		self.id = id
		self.date = date
		self.subsystem = subsystem
		self.category = category
		self.level = level
		self.source = source
		self.message = message
	}

	public var formattedTime: String {
		let formatter = DateFormatter()
		formatter.dateFormat = "HH:mm:ss.SSS"
		return formatter.string(from: date)
	}

	public var formattedFullDate: String {
		let formatter = DateFormatter()
		formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
		return formatter.string(from: date)
	}

	public var exportText: String {
		"\(formattedFullDate) [\(level.shortName)] [\(category)] \(message)"
	}
}

// MARK: - DebugLogManager

@MainActor
public final class DebugLogManager: ObservableObject {
	public static let shared = DebugLogManager()

	public enum Scope: String, CaseIterable {
		case diagnostics = "Diagnostics"
		case appActivity = "App Activity"
	}

	public enum LevelFilter: String, CaseIterable {
		case all = "All"
		case errors = "Errors"
		case warnings = "Warnings"
		case info = "Info"
		case debug = "Debug"
	}

	public enum SortOrder: String, CaseIterable {
		case newestFirst = "Newest First"
		case oldestFirst = "Oldest First"
	}

	public static let loggingEnabledKey = "Feather.debug.loggingEnabled"

	@Published public private(set) var entries: [DebugLogItem] = []
	@Published public private(set) var isLoading: Bool = false
	@Published public private(set) var lastFetchDate: Date? = nil

	@Published public var isLoggingEnabled: Bool {
		didSet {
			UserDefaults.standard.set(isLoggingEnabled, forKey: Self.loggingEnabledKey)
			if isLoggingEnabled && _inMemoryEntries.isEmpty {
				log("Feather debug log session started", category: "App", level: .info)
			}
		}
	}

	@Published public var searchText: String = ""
	@Published public var selectedScope: Scope = .diagnostics
	@Published public var selectedLevel: LevelFilter = .all
	@Published public var selectedCategory: String = "All"
	@Published public var sortOrder: SortOrder = .newestFirst

	private var _inMemoryEntries: [DebugLogItem] = []
	private let _maxInMemoryCount: Int = 1000
	private let _lock = NSLock()
	private let _logger = Logger(
		subsystem: Bundle.main.bundleIdentifier ?? "Feather",
		category: "Diagnostics"
	)

	private init() {
		let enabled = UserDefaults.standard.bool(forKey: Self.loggingEnabledKey)
		self.isLoggingEnabled = enabled
		if enabled {
			log("Feather debug log session started", category: "App", level: .info)
		}
	}

	// MARK: - Logging API

	public func log(
		_ message: String,
		category: String = "Misc",
		level: DebugLogItem.Level = .info
	) {
		guard isLoggingEnabled else { return }

		let item = DebugLogItem(
			date: Date(),
			subsystem: Bundle.main.bundleIdentifier ?? "Feather",
			category: category,
			level: level,
			source: .diagnostics,
			message: message
		)

		_lock.lock()
		_inMemoryEntries.append(item)
		if _inMemoryEntries.count > _maxInMemoryCount {
			_inMemoryEntries.removeFirst(_inMemoryEntries.count - _maxInMemoryCount)
		}
		_lock.unlock()

		DispatchQueue.main.async { [weak self] in
			guard let self else { return }
			if !self.entries.contains(where: { $0.id == item.id }) {
				self.entries.insert(item, at: 0)
			}
		}

		switch level {
		case .debug:
			_logger.debug("\(message, privacy: .public)")
		case .info:
			_logger.info("\(message, privacy: .public)")
		case .notice:
			_logger.notice("\(message, privacy: .public)")
		case .warning:
			_logger.warning("\(message, privacy: .public)")
		case .error:
			_logger.error("\(message, privacy: .public)")
		case .fault:
			_logger.fault("\(message, privacy: .public)")
		case .unknown:
			_logger.notice("\(message, privacy: .public)")
		}
	}

	public func clearDiagnostics() {
		_lock.lock()
		_inMemoryEntries.removeAll()
		_lock.unlock()
		DispatchQueue.main.async { [weak self] in
			self?.entries.removeAll { $0.source == .diagnostics }
		}
	}

	// MARK: - OSLogStore Fetching

	public func fetchLogs(timeInterval: TimeInterval = 3600 * 24) async {
		guard !isLoading else { return }
		isLoading = true
		defer { isLoading = false }

		_lock.lock()
		let memoryItems = _inMemoryEntries
		_lock.unlock()

		let fetched = await Task.detached(priority: .userInitiated) { () -> [DebugLogItem] in
			var results: [DebugLogItem] = []
			do {
				let store = try OSLogStore(scope: .currentProcessIdentifier)
				let position = store.position(date: Date().addingTimeInterval(-timeInterval))
				let entries = try store.getEntries(at: position)

				for entry in entries {
					guard let log = entry as? OSLogEntryLog else { continue }
					let msg = log.composedMessage
					if msg.isEmpty || msg.contains("<compose failure") {
						continue
					}

					let item = DebugLogItem(
						id: UUID(),
						date: log.date,
						subsystem: log.subsystem,
						category: log.category.isEmpty ? "Default" : log.category,
						level: DebugLogItem.Level(from: log.level),
						source: .appActivity,
						message: msg
					)
					results.append(item)
				}
			} catch {
				// OSLogStore might fail in restricted environments; fallback to memory items
			}
			return results
		}.value

		// Combine fetched OSLogStore items with memory items, avoiding duplicates in O(N)
		var seenKeys = Set<String>()
		var combined: [DebugLogItem] = []
		combined.reserveCapacity(memoryItems.count + fetched.count)

		func dedupeKey(for item: DebugLogItem) -> String {
			"\(item.source.rawValue)|\(item.category)|\(item.message)|\(Int(item.date.timeIntervalSince1970))"
		}

		for item in memoryItems {
			seenKeys.insert(dedupeKey(for: item))
			combined.append(item)
		}

		for item in fetched {
			let k = dedupeKey(for: item)
			if !seenKeys.contains(k) {
				seenKeys.insert(k)
				combined.append(item)
			}
		}

		// Sort newest first by default
		combined.sort { $0.date > $1.date }

		await MainActor.run {
			self.entries = combined
			self.lastFetchDate = Date()
		}
	}

	// MARK: - Filtered Views

	public var availableCategories: [String] {
		var cats = Set<String>()
		for item in entries {
			if item.source == selectedScope.logSource {
				cats.insert(item.category)
			}
		}
		let sorted = cats.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
		return ["All"] + sorted
	}

	public var filteredEntries: [DebugLogItem] {
		var list = entries.filter { item in
			if item.source != selectedScope.logSource {
				return false
			}

			// Level filter
			switch selectedLevel {
			case .all:
				break
			case .errors:
				if item.level != .error && item.level != .fault { return false }
			case .warnings:
				if item.level != .warning && item.level != .error && item.level != .fault { return false }
			case .info:
				if item.level != .info { return false }
			case .debug:
				if item.level != .debug { return false }
			}

			// Category filter
			if selectedCategory != "All" && item.category != selectedCategory {
				return false
			}

			// Search text
			if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
				let query = searchText.lowercased()
				let matchesMessage = item.message.lowercased().contains(query)
				let matchesCategory = item.category.lowercased().contains(query)
				let matchesSubsystem = item.subsystem.lowercased().contains(query)
				if !matchesMessage && !matchesCategory && !matchesSubsystem {
					return false
				}
			}

			return true
		}

		if sortOrder == .oldestFirst {
			list.sort { $0.date < $1.date }
		} else {
			list.sort { $0.date > $1.date }
		}

		return list
	}

	// MARK: - Export

	public func exportAllText(filteredOnly: Bool = true) -> String {
		let list = filteredOnly ? filteredEntries : entries
		let header = "--- Feather Debug Logs Export (\(Date())) ---\nTotal: \(list.count) entries\n\n"
		let lines = list.map { $0.exportText }.joined(separator: "\n")
		return header + lines
	}

	public func exportLogFile(filteredOnly: Bool = true) -> URL? {
		let text = exportAllText(filteredOnly: filteredOnly)
		let tempDir = FileManager.default.temporaryDirectory
		let fileName = "Feather-Logs-\(Int(Date().timeIntervalSince1970)).txt"
		let fileURL = tempDir.appendingPathComponent(fileName)

		do {
			try text.write(to: fileURL, atomically: true, encoding: .utf8)
			return fileURL
		} catch {
			return nil
		}
	}
}

private extension DebugLogManager.Scope {
	var logSource: DebugLogItem.Source {
		switch self {
		case .diagnostics: return .diagnostics
		case .appActivity: return .appActivity
		}
	}
}
