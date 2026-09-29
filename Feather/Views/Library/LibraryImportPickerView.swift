//
//  LibraryImportPickerView.swift
//  Feather
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
		picker.delegate = context.coordinator
		picker.allowsMultipleSelection = true
		return picker
	}

	func updateUIViewController(_ uiViewController: LibraryDocumentPickerViewController, context: Context) {}

	final class Coordinator: NSObject, UIDocumentPickerDelegate {
		private let onDocumentsPicked: ([URL]) -> Void

		init(onDocumentsPicked: @escaping ([URL]) -> Void) {
			self.onDocumentsPicked = onDocumentsPicked
		}

		func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
			onDocumentsPicked(urls)
		}

		func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
			onDocumentsPicked([])
		}
	}
}

final class LibraryDocumentPickerViewController: UIDocumentPickerViewController {}
