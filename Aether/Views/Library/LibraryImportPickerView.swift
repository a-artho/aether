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
		let types = Self.importTypes()
		let picker = LibraryDocumentPickerViewController(
			forOpeningContentTypes: types,
			asCopy: true
		)
		let identifiers = types.map(\.identifier).joined(separator: ", ")
		DebugLogManager.shared.log("Library file picker created: copy-based, single selection; allowed types=[\(identifiers)].", category: "Import", level: .debug)
		picker.delegate = context.coordinator
		picker.allowsMultipleSelection = false
		return picker
	}

	func updateUIViewController(_ uiViewController: LibraryDocumentPickerViewController, context: Context) {
		context.coordinator.onDocumentsPicked = onDocumentsPicked
	}

	/// File providers can identify the same archive using different declared UTIs.
	/// Resolve all registered variants for each presentation instead of retaining
	/// the single preferred extension mapping for the lifetime of the app.
	private static func importTypes() -> [UTType] {
		var types = [UTType.zip]
		for ext in ["ipa", "tipa"] {
			types += UTType.types(tag: ext, tagClass: .filenameExtension, conformingTo: nil)
		}
		for identifier in ["com.apple.itunes.ipa", "com.anfear.aether.ipa", "com.anfear.aether.tipa"] {
			if let type = UTType(identifier) { types.append(type) }
		}
		var seen = Set<String>()
		return types.filter { seen.insert($0.identifier).inserted }
	}

	final class Coordinator: NSObject, UIDocumentPickerDelegate {
		var onDocumentsPicked: ([URL]) -> Void
		private var completed = false

		init(onDocumentsPicked: @escaping ([URL]) -> Void) {
			self.onDocumentsPicked = onDocumentsPicked
		}

		func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
			guard !completed else { return }
			completed = true
			DebugLogManager.shared.log("Library file picker selected \(urls.count) file(s): \(urls.map(\.lastPathComponent).joined(separator: ", ")).", category: "Import")
			onDocumentsPicked(urls)
		}

		func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
			guard !completed else { return }
			completed = true
			DebugLogManager.shared.log("Library file picker cancelled.", category: "Import", level: .debug)
			onDocumentsPicked([])
		}
	}
}

final class LibraryDocumentPickerViewController: UIDocumentPickerViewController {}
