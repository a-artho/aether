//
//  LibraryImportPickerView.swift
//  Aether
//

import SwiftUI
import UniformTypeIdentifiers

struct LibraryImportPickerView: UIViewControllerRepresentable {
	let onDocumentsPicked: ([URL]) -> Void

	func makeCoordinator() -> Coordinator {
		Coordinator(onDocumentsPicked: onDocumentsPicked)
	}

	func makeUIViewController(context: Context) -> LibraryDocumentPickerViewController {
		let picker = LibraryDocumentPickerViewController(
			forOpeningContentTypes: [.ipa, .tipa],
			asCopy: false
		)
		picker.delegate = context.coordinator
		picker.allowsMultipleSelection = true
		if let source = LibraryImportLocation.resolve() {
			context.coordinator.useSource(source)
			picker.directoryURL = source.deletingLastPathComponent()
		} else {
			// Do not inherit the certificate picker's system-wide last location.
			picker.directoryURL = URL.documentsDirectory
		}
		return picker
	}

	func updateUIViewController(_ uiViewController: LibraryDocumentPickerViewController, context: Context) {}

	final class Coordinator: NSObject, UIDocumentPickerDelegate {
		private let onDocumentsPicked: ([URL]) -> Void
		private var accessedSource: URL?

		func useSource(_ url: URL) {
			if url.startAccessingSecurityScopedResource() { accessedSource = url }
		}

		deinit { accessedSource?.stopAccessingSecurityScopedResource() }

		init(onDocumentsPicked: @escaping ([URL]) -> Void) {
			self.onDocumentsPicked = onDocumentsPicked
		}

		func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
			if let source = urls.first { LibraryImportLocation.save(source) }
			onDocumentsPicked(urls)
		}

		func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
			onDocumentsPicked([])
		}
	}
}

final class LibraryDocumentPickerViewController: UIDocumentPickerViewController {}


/// Keep Library's source location independent of certificate and pairing pickers.
/// Bookmark the selected file: iOS grants access to that file, not its parent.
@MainActor
private enum LibraryImportLocation {
	static let key = "Aether.libraryImportSourceBookmark"

	static func resolve() -> URL? {
		guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
		var stale = false
		guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale), !stale else {
			UserDefaults.standard.removeObject(forKey: key)
			return nil
		}
		return url
	}

	static func save(_ url: URL) {
		let accessing = url.startAccessingSecurityScopedResource()
		defer { if accessing { url.stopAccessingSecurityScopedResource() } }
		do {
			let data = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
			UserDefaults.standard.set(data, forKey: key)
		} catch {
			DebugLogManager.shared.log("Could not remember Library import location: \(error.localizedDescription)", category: "Import", level: .notice)
		}
	}
}
