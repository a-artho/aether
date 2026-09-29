//
//  SourcesAddView.swift
//  Feather
//
//  Created by samara on 1.05.2025.
//

import SwiftUI
import NimbleViews
import AltSourceKit
import NimbleJSON
import OSLog
import UIKit.UIImpactFeedbackGenerator

// MARK: - View
struct SourcesAddView: View {
	typealias RepositoryDataHandler = Result<ASRepository, Error>
	@Environment(\.dismiss) var dismiss

	private let _dataService = NBFetchService()

	@State private var _isImporting = false
	@State private var _isSaving = false
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
		FR.handleSource(_sourceURL) { success in
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
				NBToolbarButton(role: .cancel)
				
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
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Feather.triggerSaveSource"))) { _ in
				_saveSource()
			}
		}
		.presentationDetents([.height(370)])
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
		
		Task {
			let fetched = await _concurrentFetchRepositories(from: repoUrls)
			
			let dict = Dictionary(fetched, uniquingKeysWith: { first, _ in first })

			await MainActor.run {
				Storage.shared.addSources(repos: dict) { _ in
					_isImporting = false
					completion()
				}
			}
		}
	}
	
	private func _concurrentFetchRepositories(
		from urls: [URL]
	) async -> [(url: URL, data: ASRepository)] {
		var results: [(url: URL, data: ASRepository)] = []
		let dataService = _dataService
		
		await withTaskGroup(of: (url: URL, data: ASRepository)?.self) { group in
			for url in urls {
				group.addTask {
					await withCheckedContinuation { continuation in
						dataService.fetch<ASRepository>(from: url) { (result: RepositoryDataHandler) in
							switch result {
							case .success(let repo):
								continuation.resume(returning: (url: url, data: repo))
							case .failure(let error):
								Logger.misc.error("Failed to fetch \(url): \(error.localizedDescription)")
								continuation.resume(returning: nil)
							}
						}
					}
				}
			}
			for await item in group {
				if let item {
					results.append(item)
				}
			}
		}
		
		return results
	}

}
