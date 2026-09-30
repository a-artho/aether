//
//  SandboxBrowserView.swift
//  Aether
//

import SwiftUI
import IDeviceSwift
import NimbleViews
import UniformTypeIdentifiers
import Zip

struct SandboxBrowserView: View {
	private enum SandboxAccessError: LocalizedError {
		case pairingFileMissing
		case deviceDisconnected

		var errorDescription: String? {
			switch self {
			case .pairingFileMissing:
				return .localized("A pairing file is required to access app files.")
			case .deviceDisconnected:
				return .localized("Connect the device tunnel to access app files.")
			}
		}
	}

	let app: InstalledApp
	let initialPath: String
	@State private var currentPath: String
	@State private var items: [SandboxItem] = []
	@State private var isLoading = false
	@State private var errorMessage: String?
	@State private var isCreatingFolder = false
	@State private var newFolderName = ""
	@State private var isDocumentPickerPresented = false
	@State private var shareItem: _ShareItem?
	@State private var exportingPaths: Set<String> = []
	@State private var searchText = ""

	init(app: InstalledApp, path: String = "/") {
		self.app = app
		self.initialPath = path
		_currentPath = State(initialValue: path)
	}

	var body: some View {
		List {
			Section {
				_pathHeader
					.listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
					.listRowBackground(Color.clear)
					.listRowSeparator(.hidden)
			}

			if isLoading && items.isEmpty {
				Section {
					HStack {
						Spacer()
						ProgressView()
							.padding(.vertical, 30)
						Spacer()
					}
					.listRowBackground(Color.clear)
				}
			} else if let error = errorMessage, items.isEmpty {
				Section {
					VStack(spacing: 8) {
						Image(systemName: "exclamationmark.triangle")
							.font(.largeTitle)
							.foregroundStyle(.orange)
						Text(.localized("Unable to Load Files"))
							.font(.headline)
						Text(error)
							.font(.caption)
							.foregroundStyle(.secondary)
							.multilineTextAlignment(.center)
						Button(.localized("Retry")) {
							Task { await _loadDirectory() }
						}
						.buttonStyle(.borderedProminent)
						.controlSize(.small)
						.padding(.top, 4)
					}
					.frame(maxWidth: .infinity)
					.padding(.vertical, 24)
					.listRowBackground(Color.clear)
				}
			} else if filteredItems.isEmpty {
				Section {
					VStack(spacing: 8) {
						Image(systemName: "folder")
							.font(.largeTitle)
							.foregroundStyle(.secondary)
						Text(searchText.isEmpty ? .localized("Folder is Empty") : .localized("No Matches Found"))
							.font(.headline)
							.foregroundStyle(.secondary)
					}
					.frame(maxWidth: .infinity)
					.padding(.vertical, 36)
					.listRowBackground(Color.clear)
				}
			} else {
				Section {
					ForEach(filteredItems) { item in
						_fileRow(item)
					}
				}
			}
		}
		.listStyle(.insetGrouped)
		.searchable(text: $searchText, prompt: .localized("Search files"))
		.navigationTitle(_navTitle)
		.navigationBarTitleDisplayMode(.inline)
		.toolbar {
			ToolbarItemGroup(placement: .topBarTrailing) {
				Button {
					isCreatingFolder = true
				} label: {
					Image(systemName: "folder.badge.plus")
				}
				.accessibilityLabel(.localized("New Folder"))
				.disabled(!_canAccessSandbox)

				Button {
					isDocumentPickerPresented = true
				} label: {
					Image(systemName: "plus")
				}
				.accessibilityLabel(.localized("Import File"))
				.disabled(!_canAccessSandbox)
			}
		}
		.refreshable {
			await _loadDirectory()
		}
		.task {
			await _loadDirectory()
		}
		.alert(.localized("New Folder"), isPresented: $isCreatingFolder) {
			TextField(.localized("Folder Name"), text: $newFolderName)
			Button(.localized("Create")) {
				let folder = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
				guard !folder.isEmpty else { return }
				Task { await _createDirectory(name: folder) }
				newFolderName = ""
			}
			Button(.localized("Cancel"), role: .cancel) {
				newFolderName = ""
			}
		}
		.sheet(isPresented: $isDocumentPickerPresented) {
			_DocumentPicker { url in
				Task { await _importFile(from: url) }
			}
		}
		.sheet(item: $shareItem) { item in
			_ActivityView(activityItems: [item.url])
		}
	}

	private var _navTitle: String {
		if currentPath == "/" {
			return .localized("Sandbox")
		}
		return (currentPath as NSString).lastPathComponent
	}

	private var _pathHeader: some View {
		HStack(spacing: 6) {
			Image(systemName: "shippingbox.fill")
				.foregroundStyle(.secondary)
				.font(.caption)

			Text(currentPath)
				.font(.caption.monospaced())
				.foregroundStyle(.secondary)
				.lineLimit(1)
				.truncationMode(.middle)

			Spacer(minLength: 0)

			Text("\(filteredItems.count) item\(filteredItems.count == 1 ? "" : "s")")
				.font(.caption2.weight(.medium))
				.foregroundStyle(.tertiary)
		}
		.padding(.horizontal, 4)
	}

	private var filteredItems: [SandboxItem] {
		if searchText.isEmpty {
			return items
		}
		return items.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
	}

	private var _hasDeviceSandboxAccess: Bool {
		DeviceConnectionManager.shared.isConnected && HeartbeatManager.hasPairingFile()
	}

	private var _canAccessSandbox: Bool {
		#if DEBUG
		true
		#else
		_hasDeviceSandboxAccess
		#endif
	}

	private func _requireDeviceSandboxAccess() throws {
		guard HeartbeatManager.hasPairingFile() else {
			throw SandboxAccessError.pairingFileMissing
		}
		guard DeviceConnectionManager.shared.isConnected else {
			throw SandboxAccessError.deviceDisconnected
		}
	}

	@ViewBuilder
	private func _fileRow(_ item: SandboxItem) -> some View {
		if item.isDirectory {
			NavigationLink {
				SandboxBrowserView(app: app, path: item.path)
			} label: {
				_itemLabel(item)
			}
			.contextMenu {
				Button {
					Task { await _exportItem(item) }
				} label: {
					Label(.localized("Export Folder"), systemImage: "square.and.arrow.up")
				}
				.disabled(_isExporting(item))

				Divider()

				Button(role: .destructive) {
					Task { await _deleteItem(item) }
				} label: {
					Label(.localized("Delete Folder"), systemImage: "trash")
				}
			}
			.swipeActions(edge: .trailing, allowsFullSwipe: false) {
				Button(role: .destructive) {
					Task { await _deleteItem(item) }
				} label: {
					Label(.localized("Delete"), systemImage: "trash")
				}
			}
			.swipeActions(edge: .leading) {
				Button {
					Task { await _exportItem(item) }
				} label: {
					Label(.localized("Export"), systemImage: "square.and.arrow.up")
				}
				.tint(.blue)
			}
		} else {
			Button {
				Task { await _exportItem(item) }
			} label: {
				_itemLabel(item)
			}
			.buttonStyle(.plain)
			.disabled(_isExporting(item))
			.contextMenu {
				Button {
					Task { await _exportItem(item) }
				} label: {
					Label(.localized("Export & Share"), systemImage: "square.and.arrow.up")
				}
				.disabled(_isExporting(item))

				Divider()

				Button(role: .destructive) {
					Task { await _deleteItem(item) }
				} label: {
					Label(.localized("Delete File"), systemImage: "trash")
				}
			}
			.swipeActions(edge: .trailing, allowsFullSwipe: false) {
				Button(role: .destructive) {
					Task { await _deleteItem(item) }
				} label: {
					Label(.localized("Delete"), systemImage: "trash")
				}
			}
			.swipeActions(edge: .leading) {
				Button {
					Task { await _exportItem(item) }
				} label: {
					Label(.localized("Share"), systemImage: "square.and.arrow.up")
				}
				.tint(.blue)
			}
		}
	}

	@ViewBuilder
	private func _itemLabel(_ item: SandboxItem) -> some View {
		HStack(spacing: 14) {
			_iconView(for: item)
				.frame(width: 32, height: 32)

			VStack(alignment: .leading, spacing: 3) {
				Text(item.name)
					.font(.body.weight(.medium))
					.foregroundStyle(.primary)
					.lineLimit(1)

				HStack(spacing: 6) {
					if !item.isDirectory {
						Text(_formattedSize(item.size))
							.font(.caption2)
							.foregroundStyle(.secondary)
					}
					if let mod = item.modifiedDate {
						if !item.isDirectory {
							Text("•")
								.font(.caption2)
								.foregroundStyle(.tertiary)
						}
						Text(mod.formatted(date: .numeric, time: .shortened))
							.font(.caption2)
							.foregroundStyle(.secondary)
					}
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)

			if _isExporting(item) {
				ProgressView()
					.controlSize(.small)
					.accessibilityLabel(.localized("Exporting"))
			}
		}
		.padding(.vertical, 2)
	}

	@ViewBuilder
	private func _iconView(for item: SandboxItem) -> some View {
		if item.isDirectory {
			Image(systemName: "folder.fill")
				.font(.system(size: 24))
				.foregroundStyle(.blue)
		} else {
			let ext = (item.name as NSString).pathExtension.lowercased()
			switch ext {
			case "png", "jpg", "jpeg", "heic", "gif", "svg":
				Image(systemName: "photo.fill")
					.font(.system(size: 22))
					.foregroundStyle(.purple)
			case "plist", "json", "xml", "txt", "log", "md":
				Image(systemName: "doc.text.fill")
					.font(.system(size: 22))
					.foregroundStyle(.orange)
			case "sqlite", "sqlite3", "db":
				Image(systemName: "cylinder.split.1x2.fill")
					.font(.system(size: 22))
					.foregroundStyle(.green)
			case "zip", "tar", "gz", "ipa":
				Image(systemName: "doc.zipper")
					.font(.system(size: 22))
					.foregroundStyle(.yellow)
			case "swift", "m", "h", "js", "html", "css":
				Image(systemName: "chevron.left.forwardslash.chevron.right")
					.font(.system(size: 20, weight: .bold))
					.foregroundStyle(.teal)
			default:
				Image(systemName: "doc.fill")
					.font(.system(size: 22))
					.foregroundStyle(.secondary)
			}
		}
	}

	private func _formattedSize(_ bytes: Int64) -> String {
		let formatter = ByteCountFormatter()
		formatter.countStyle = .file
		return formatter.string(fromByteCount: bytes)
	}

	private func _loadDirectory() async {
		isLoading = true
		errorMessage = nil
		defer { isLoading = false }

		do {
			if _hasDeviceSandboxAccess {
				items = try await HouseArrestService.contentsOfDirectory(
					bundleIdentifier: app.bundleIdentifier,
					path: currentPath
				)
			} else {
				#if DEBUG
				try await Task.sleep(for: .milliseconds(120))
				items = _mockItems(for: currentPath)
				#else
				try _requireDeviceSandboxAccess()
				#endif
			}
		} catch {
			errorMessage = error.localizedDescription
		}
	}

	private func _createDirectory(name: String) async {
		let target = currentPath.hasSuffix("/") ? currentPath + name : currentPath + "/" + name
		do {
			if _hasDeviceSandboxAccess {
				try await HouseArrestService.createDirectory(
					bundleIdentifier: app.bundleIdentifier,
					path: target
				)
			} else {
				#if DEBUG
				items.append(SandboxItem(name: name, path: target, isDirectory: true, size: 0, modifiedDate: Date()))
				items.sort { $0.isDirectory && !$1.isDirectory }
				#else
				try _requireDeviceSandboxAccess()
				#endif
			}
			await _loadDirectory()
		} catch {
			errorMessage = error.localizedDescription
		}
	}

	private func _deleteItem(_ item: SandboxItem) async {
		do {
			if _hasDeviceSandboxAccess {
				try await HouseArrestService.deleteItem(
					bundleIdentifier: app.bundleIdentifier,
					path: item.path
				)
				withAnimation {
					items.removeAll { $0.path == item.path }
				}
			} else {
				#if DEBUG
				withAnimation {
					items.removeAll { $0.path == item.path }
				}
				#else
				try _requireDeviceSandboxAccess()
				#endif
			}
		} catch {
			errorMessage = error.localizedDescription
		}
	}

	private func _importFile(from fileURL: URL) async {
		guard fileURL.startAccessingSecurityScopedResource() else { return }
		defer { fileURL.stopAccessingSecurityScopedResource() }

		do {
			let filename = fileURL.lastPathComponent
			let target = currentPath.hasSuffix("/") ? currentPath + filename : currentPath + "/" + filename

			if _hasDeviceSandboxAccess {
				try await HouseArrestService.copyFileToDevice(
					bundleIdentifier: app.bundleIdentifier,
					from: fileURL,
					to: target
				)
			} else {
				#if DEBUG
				let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
				items.append(
					SandboxItem(
						name: filename,
						path: target,
						isDirectory: false,
						size: Int64(values.fileSize ?? 0),
						modifiedDate: Date()
					)
				)
				#else
				try _requireDeviceSandboxAccess()
				#endif
			}
			await _loadDirectory()
		} catch {
			errorMessage = error.localizedDescription
		}
	}

	private func _exportItem(_ item: SandboxItem) async {
		guard exportingPaths.insert(item.path).inserted else { return }
		defer { exportingPaths.remove(item.path) }

		do {
			if _hasDeviceSandboxAccess {
				let destination = _exportDirectory.appendingPathComponent("\(UUID().uuidString)-\(item.name)", isDirectory: item.isDirectory)
				if item.isDirectory {
					try await HouseArrestService.copyDirectoryFromDevice(
						bundleIdentifier: app.bundleIdentifier,
						path: item.path,
						to: destination
					)
					let archive = destination.deletingLastPathComponent()
						.appendingPathComponent("\(destination.lastPathComponent).zip")
					try await Task.detached(priority: .utility) {
						try Zip.zipFiles(
							paths: [destination],
							zipFilePath: archive,
							password: nil,
							compression: .DefaultCompression,
							progress: nil
						)
					}.value
					try? FileManager.default.removeItem(at: destination)
					_presentShareItem(for: archive)
				} else {
					try await HouseArrestService.copyFileFromDevice(
						bundleIdentifier: app.bundleIdentifier,
						path: item.path,
						to: destination
					)
					_presentShareItem(for: destination)
				}
			} else {
				#if DEBUG
				let destination = _exportDirectory.appendingPathComponent("\(UUID().uuidString)-\(item.name)", isDirectory: item.isDirectory)
				if item.isDirectory {
					try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
					let archive = destination.deletingLastPathComponent()
						.appendingPathComponent("\(destination.lastPathComponent).zip")
					try await Task.detached(priority: .utility) {
						try Zip.zipFiles(paths: [destination], zipFilePath: archive, password: nil, compression: .DefaultCompression, progress: nil)
					}.value
					try? FileManager.default.removeItem(at: destination)
					_presentShareItem(for: archive)
				} else {
					try FileManager.default.createDirectory(at: _exportDirectory, withIntermediateDirectories: true)
					try Data("Sample file content for \(item.name)".utf8).write(to: destination, options: .atomic)
					_presentShareItem(for: destination)
				}
				#else
				try _requireDeviceSandboxAccess()
				#endif
			}
		} catch {
			errorMessage = error.localizedDescription
		}
	}

	private var _exportDirectory: URL {
		FileManager.default.temporaryDirectory
			.appendingPathComponent("AetherSandboxExports", isDirectory: true)
	}

	private func _presentShareItem(for url: URL) {
		shareItem = _ShareItem(url: url)
	}

	private func _isExporting(_ item: SandboxItem) -> Bool {
		exportingPaths.contains(item.path)
	}

	#if DEBUG
	private func _mockItems(for path: String) -> [SandboxItem] {
		if path == "/" {
			return [
				SandboxItem(name: "Documents", path: "/Documents", isDirectory: true, size: 0, modifiedDate: Date()),
				SandboxItem(name: "Library", path: "/Library", isDirectory: true, size: 0, modifiedDate: Date()),
				SandboxItem(name: "tmp", path: "/tmp", isDirectory: true, size: 0, modifiedDate: Date()),
				SandboxItem(name: "Info.plist", path: "/Info.plist", isDirectory: false, size: 4120, modifiedDate: Date().addingTimeInterval(-86400)),
				SandboxItem(name: "app_state.json", path: "/app_state.json", isDirectory: false, size: 18240, modifiedDate: Date().addingTimeInterval(-3600 * 2))
			]
		} else if path == "/Documents" {
			return [
				SandboxItem(name: "Saves", path: "/Documents/Saves", isDirectory: true, size: 0, modifiedDate: Date()),
				SandboxItem(name: "database.sqlite", path: "/Documents/database.sqlite", isDirectory: false, size: 245760, modifiedDate: Date()),
				SandboxItem(name: "config.json", path: "/Documents/config.json", isDirectory: false, size: 2048, modifiedDate: Date())
			]
		} else {
			return [
				SandboxItem(name: "Preferences", path: "\(path)/Preferences", isDirectory: true, size: 0, modifiedDate: Date()),
				SandboxItem(name: "cache.data", path: "\(path)/cache.data", isDirectory: false, size: 65536, modifiedDate: Date())
			]
		}
	}
	#endif
}

private struct _ShareItem: Identifiable {
	let id = UUID()
	let url: URL
}

private struct _DocumentPicker: UIViewControllerRepresentable {
	let onPick: (URL) -> Void

	func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
		let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
		picker.delegate = context.coordinator
		picker.allowsMultipleSelection = false
		return picker
	}

	func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

	func makeCoordinator() -> Coordinator {
		Coordinator(onPick: onPick)
	}

	class Coordinator: NSObject, UIDocumentPickerDelegate {
		let onPick: (URL) -> Void

		init(onPick: @escaping (URL) -> Void) {
			self.onPick = onPick
		}

		func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
			guard let first = urls.first else { return }
			onPick(first)
		}
	}
}

private struct _ActivityView: UIViewControllerRepresentable {
	let activityItems: [Any]

	func makeUIViewController(context: Context) -> UIActivityViewController {
		UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
	}

	func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
