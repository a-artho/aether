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
			asCopy: true
		)
		DebugLogManager.shared.log("Library file picker created: copy-based import, IPA/TIPA, single selection.", category: "Import", level: .debug)
		picker.delegate = context.coordinator
		picker.allowsMultipleSelection = false
		return picker
	}

	func updateUIViewController(_ uiViewController: LibraryDocumentPickerViewController, context: Context) {}

	final class Coordinator: NSObject, UIDocumentPickerDelegate {
		private let onDocumentsPicked: ([URL]) -> Void

		init(onDocumentsPicked: @escaping ([URL]) -> Void) {
			self.onDocumentsPicked = onDocumentsPicked
		}

		func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
			DebugLogManager.shared.log("Library file picker selected \(urls.count) file(s): \(urls.map(\.lastPathComponent).joined(separator: ", ")).", category: "Import")
			onDocumentsPicked(urls)
		}

		func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
			DebugLogManager.shared.log("Library file picker cancelled.", category: "Import", level: .debug)
			onDocumentsPicked([])
		}
	}
}

final class LibraryDocumentPickerViewController: UIDocumentPickerViewController {}
