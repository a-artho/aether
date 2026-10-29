//
//  SourcesAddView.swift
//  Aether
//
//  Created by samara on 1.05.2025.
//

import SwiftUI
import NimbleViews
import AltSourceKit

// MARK: - View
struct SourcesAddView: View {
	@Environment(\.dismiss) var dismiss

	@State private var _isImporting = false
	@State private var _isSaving = false
	@State private var _pendingTask: Task<Void, Never>?
	@State private var _operationID = UUID()
	@State private var _sourceURL: String
	private let _initialURL: String
	
	init(initialURL: String = "") {
		self._initialURL = initialURL
		self.__sourceURL = State(initialValue: initialURL)
	}
	
	private var _isSaveDisabled: Bool {
		_sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || _isSaving || _isImporting
	}
	
	private func _saveSource() {
		guard !_isSaveDisabled else { return }
		_isSaving = true
		let operation = UUID()
		_operationID = operation
		_pendingTask = FR.handleSource(_sourceURL, shouldCommit: { _operationID == operation }) { success in
			_isSaving = false
			if success {
				dismiss()
			}
		}
	}
	
	// MARK: Body
	var body: some View {
		NBNavigationView(.localized("Add Source"), displayMode: .inline) {
			Form {
				NBSection(.localized("Source URL")) {
					TextField(.localized("Enter Source URL"), text: $_sourceURL)
						.keyboardType(.URL)
						.textInputAutocapitalization(.never)
						.disabled(_isSaving || _isImporting)
						.onSubmit {
							if !_isSaveDisabled {
								_saveSource()
							}
						}
				} footer: {
					Text(.localized("The only supported repos are AltStore repos."))
					Text(verbatim: "[\(String.localized("Learn more about how to setup a repo..."))](https://faq.altstore.io/developers/make-a-source)")
				}
				
				Section {
					Button {
						_isImporting = true
						_fetchImportedRepositories(UIPasteboard.general.string) {
							dismiss()
						}
					} label: {
						SettingsRowLabel(
							.localized("Import"),
							systemImage: "square.and.arrow.down.fill",
							backgroundColor: .blue
						)
					}
					.disabled(_isSaving || _isImporting)
					
					Button {
						let sources = Storage.shared.getSources()
						guard !sources.isEmpty else {
							UIAlertController.showAlertWithOk(
								title: .localized("Error"),
								message: .localized("No sources to export")
							)
							return
						}
						UIPasteboard.general.string = sources.compactMap {
							$0.sourceURL?.absoluteString
						}.joined(separator: "\n")
						UIAlertController.showAlertWithOk(
							title: .localized("Success"),
							message: .localized("Sources copied to clipboard")
						) {
							dismiss()
						}
					} label: {
						SettingsRowLabel(
							.localized("Export"),
							systemImage: "doc.on.doc.fill",
							backgroundColor: .orange
						)
					}
					.disabled(_isSaving || _isImporting)
				} footer: {
					Text(.localized("Supports importing from KravaSign/MapleSign and ESign."))
				}
			}
			.toolbar {
				NBToolbarButton(systemImage: "xmark", placement: .cancellationAction) {
					_cancelPendingOperation()
					dismiss()
				}
				
				if !_isSaving && !_isImporting {
					NBToolbarButton(
						systemImage: "checkmark",
						style: .icon,
						placement: .confirmationAction,
						isDisabled: _isSaveDisabled
					) {
						_saveSource()
					}
				} else {
					ToolbarItem(placement: .confirmationAction) {
						ProgressView()
					}
				}
			}
			.onAppear {
				if !_initialURL.isEmpty {
					_sourceURL = _initialURL
				}
			}
			#if DEBUG
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Aether.triggerSaveSource"))) { _ in
				_saveSource()
			}
			#endif
		}
		.presentationDetents([.height(370)])
		.onDisappear { _cancelPendingOperation() }
	}
	
	private func _fetchImportedRepositories(
		_ code: String?,
		completion: @escaping () -> Void
	) {
		guard let code else {
			_isImporting = false
			UIAlertController.showAlertWithOk(title: .localized("Error"), message: .localized("Clipboard is empty."))
			return
		}
		
		let handler = ASDeobfuscator(with: code)
		let repoUrls = handler.decode().compactMap { URL(string: $0) }
		guard !repoUrls.isEmpty else {
			_isImporting = false
			UIAlertController.showAlertWithOk(title: .localized("Error"), message: .localized("No valid sources found in clipboard."))
			return
		}
		
		let operation = UUID()
		_operationID = operation
		_pendingTask = Task { @MainActor in
			let snapshots = await SourceRepositoryService.shared.snapshots(from: repoUrls)
			guard !Task.isCancelled, _operationID == operation else { return }
			guard !snapshots.isEmpty else {
				_isImporting = false
				UIAlertController.showAlertWithOk(title: .localized("Error"), message: .localized("No sources could be imported."))
				return
			}
			Storage.shared.addSources(repos: snapshots.mapValues(\.repository)) { error in
				_isImporting = false
				if let error {
					UIAlertController.showAlertWithOk(title: .localized("Error"), message: error.localizedDescription)
					return
				}
				SourcesViewModel.shared.cache(snapshots)
				completion()
			}
		}
	}

	private func _cancelPendingOperation() {
		_operationID = UUID()
		_pendingTask?.cancel()
		_pendingTask = nil
		_isSaving = false
		_isImporting = false
	}
}
