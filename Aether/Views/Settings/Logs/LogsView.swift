//
//  LogsView.swift
//  Aether
//
//  Created by samara on 29.09.2026.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

// MARK: - LogsView

struct LogsView: View {
	@StateObject private var _logManager = DebugLogManager.shared
	@State private var _selectedItemForDetail: DebugLogItem? = nil
	@State private var _showClearConfirmation: Bool = false
	@State private var _copiedToast: Bool = false

	var body: some View {
		NBList(.localized("Logs"), displayMode: .inline, type: .list) {
			// MARK: Options Section
			Section {
				Toggle(isOn: $_logManager.isLoggingEnabled) {
					SettingsRowLabel(
						.localized("Enable Logging"),
						systemImage: "doc.text.magnifyingglass",
						backgroundColor: .purple
					)
				}
			} footer: {
				Text(.localized("When enabled, diagnostics are recorded for installations, pairing, and tunneling to assist in troubleshooting."))
			}

			// MARK: Filter Section
			Section {
				Picker("Scope", selection: $_logManager.selectedScope) {
					ForEach(DebugLogManager.Scope.allCases, id: \.self) { scope in
						Text(scope.rawValue).tag(scope)
					}
				}
				.pickerStyle(.segmented)

				HStack {
					Text(.localized("Level"))
						.foregroundColor(.primary)
					Spacer()
					Menu {
						Picker("Level", selection: $_logManager.selectedLevel) {
							ForEach(DebugLogManager.LevelFilter.allCases, id: \.self) { level in
								Text(level.rawValue).tag(level)
							}
						}
					} label: {
						HStack(spacing: 4) {
							Text(_logManager.selectedLevel.rawValue)
								.foregroundColor(.secondary)
							Image(systemName: "chevron.up.chevron.down")
								.font(.caption2)
								.foregroundColor(.secondary)
						}
					}
				}

				HStack {
					Text(.localized("Category"))
						.foregroundColor(.primary)
					Spacer()
					Menu {
						Picker("Category", selection: $_logManager.selectedCategory) {
							ForEach(_logManager.availableCategories, id: \.self) { cat in
								Text(cat).tag(cat)
							}
						}
					} label: {
						HStack(spacing: 4) {
							Text(_logManager.selectedCategory)
								.foregroundColor(.secondary)
							Image(systemName: "chevron.up.chevron.down")
								.font(.caption2)
								.foregroundColor(.secondary)
						}
					}
				}
			} header: {
				Text(.localized("Filters"))
			}

			// MARK: Logs List Section
			Section {
				if _logManager.isLoading && _logManager.filteredEntries.isEmpty {
					HStack {
						Spacer()
						ProgressView(.localized("Loading logs..."))
							.padding()
						Spacer()
					}
				} else if !_logManager.isLoggingEnabled && _logManager.filteredEntries.isEmpty {
					VStack(spacing: 10) {
						Image(systemName: "doc.text.magnifyingglass")
							.font(.system(size: 34))
							.foregroundColor(.secondary)
						Text(.localized("Logging is Disabled"))
							.font(.headline)
							.foregroundColor(.primary)
						Text(.localized("Turn on Enable Logging above to record diagnostic events for installations, pairing, and tunneling."))
							.nbFont(.subheadline)
							.foregroundColor(.secondary)
							.multilineTextAlignment(.center)
							.padding(.horizontal)
					}
					.frame(maxWidth: .infinity)
					.padding(.vertical, 30)
				} else if _logManager.filteredEntries.isEmpty {
					VStack(spacing: 10) {
						Image(systemName: "doc.text.magnifyingglass")
							.font(.system(size: 34))
							.foregroundColor(.secondary)
						Text(.localized("No logs found"))
							.nbFont(.subheadline)
							.foregroundColor(.secondary)
						if !_logManager.searchText.isEmpty || _logManager.selectedLevel != .all || _logManager.selectedCategory != "All" {
							Button(.localized("Reset Filters")) {
								_logManager.searchText = ""
								_logManager.selectedLevel = .all
								_logManager.selectedCategory = "All"
							}
							.font(.footnote)
							.padding(.top, 4)
						}
					}
					.frame(maxWidth: .infinity)
					.padding(.vertical, 30)
				} else {
					ForEach(_logManager.filteredEntries) { item in
						Button {
							_selectedItemForDetail = item
						} label: {
							DebugLogRow(item: item)
						}
						.buttonStyle(.plain)
						.contextMenu {
							Button {
								UIPasteboard.general.string = item.message
								_showCopiedFeedback()
							} label: {
								Label(.localized("Copy Message"), systemImage: "doc.on.doc")
							}

							Button {
								UIPasteboard.general.string = item.exportText
								_showCopiedFeedback()
							} label: {
								Label(.localized("Copy Full Entry"), systemImage: "doc.on.clipboard")
							}

							Button {
								_logManager.selectedCategory = item.category
							} label: {
								Label(.localized("Filter by Category"), systemImage: "line.3.horizontal.decrease.circle")
							}

							Button {
								UIActivityViewController.show(activityItems: [item.exportText])
							} label: {
								Label(.localized("Share"), systemImage: "square.and.arrow.up")
							}
						}
					}
				}
			} header: {
				HStack {
					Text(.localized("Entries"))
					Spacer()
					if !_logManager.filteredEntries.isEmpty {
						Text("\(_logManager.filteredEntries.count) of \(_logManager.entries.count)")
							.font(.caption2)
							.foregroundColor(.secondary)
					}
				}
			} footer: {
				if let date = _logManager.lastFetchDate {
					HStack {
						Spacer()
						Text("Last updated: \(date, style: .time)")
							.font(.caption2)
							.foregroundColor(.secondary)
						Spacer()
					}
				}
			}
		}
		.searchable(text: $_logManager.searchText, prompt: Text(.localized("Search logs...")))
		.refreshable {
			await _logManager.fetchLogs()
		}
		.toolbar {
			ToolbarItemGroup(placement: .topBarTrailing) {
				Button {
					Task {
						await _logManager.fetchLogs()
					}
				} label: {
					if _logManager.isLoading {
						ProgressView()
							.progressViewStyle(CircularProgressViewStyle())
					} else {
						Image(systemName: "arrow.clockwise")
					}
				}
				.disabled(_logManager.isLoading)

				Menu {
					Button {
						let text = _logManager.exportAllText(filteredOnly: true)
						UIPasteboard.general.string = text
						_showCopiedFeedback()
					} label: {
						Label(.localized("Copy Filtered Logs"), systemImage: "doc.on.doc")
					}

					Button {
						let text = _logManager.exportAllText(filteredOnly: false)
						UIPasteboard.general.string = text
						_showCopiedFeedback()
					} label: {
						Label(.localized("Copy All Logs"), systemImage: "doc.on.clipboard")
					}

					Divider()

					Button {
						if let url = _logManager.exportLogFile(filteredOnly: true) {
							UIActivityViewController.show(activityItems: [url])
						}
					} label: {
						Label(.localized("Export Filtered Logs..."), systemImage: "square.and.arrow.up")
					}

					Button {
						if let url = _logManager.exportLogFile(filteredOnly: false) {
							UIActivityViewController.show(activityItems: [url])
						}
					} label: {
						Label(.localized("Export All Logs..."), systemImage: "square.and.arrow.up.fill")
					}

					Divider()

					Picker("Sort Order", selection: $_logManager.sortOrder) {
						ForEach(DebugLogManager.SortOrder.allCases, id: \.self) { order in
							Text(order.rawValue).tag(order)
						}
					}

					Divider()

					Button(role: .destructive) {
						_showClearConfirmation = true
					} label: {
						Label(.localized("Clear Diagnostics"), systemImage: "trash")
					}
				} label: {
					Image(systemName: "ellipsis.circle")
				}
			}
		}
		.confirmationDialog(
			.localized("Clear Diagnostics?"),
			isPresented: $_showClearConfirmation,
			titleVisibility: .visible
		) {
			Button(.localized("Clear Diagnostics"), role: .destructive) {
				_logManager.clearDiagnostics()
			}
			Button(.localized("Cancel"), role: .cancel) {}
		}
		.sheet(item: $_selectedItemForDetail) { item in
			DebugLogDetailView(item: item)
		}
		.overlay(alignment: .bottom) {
			if _copiedToast {
				Text(.localized("Copied to clipboard"))
					.font(.footnote.bold())
					.foregroundColor(.white)
					.padding(.horizontal, 16)
					.padding(.vertical, 8)
					.background(Color.black.opacity(0.8))
					.cornerRadius(20)
					.padding(.bottom, 20)
					.transition(.opacity.combined(with: .scale(scale: 0.9)))
			}
		}
		.animation(.easeInOut(duration: 0.2), value: _copiedToast)
		.task {
			await _logManager.fetchLogs()
		}
	}

	private func _showCopiedFeedback() {
		withAnimation { _copiedToast = true }
		DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
			withAnimation { _copiedToast = false }
		}
	}
}

// MARK: - DebugLogRow

struct DebugLogRow: View {
	let item: DebugLogItem

	var body: some View {
		VStack(alignment: .leading, spacing: 5) {
			HStack(spacing: 6) {
				Text(item.level.shortName)
					.font(.system(size: 9.5, weight: .bold, design: .monospaced))
					.foregroundColor(item.level.color)
					.padding(.horizontal, 4)
					.padding(.vertical, 2)
					.background(item.level.color.opacity(0.14))
					.cornerRadius(4)

				Text(item.category)
					.font(.system(size: 11, weight: .semibold))
					.foregroundColor(.secondary)
					.lineLimit(1)

				Spacer()

				Text(item.formattedTime)
					.font(.system(size: 11, weight: .regular, design: .monospaced))
					.foregroundColor(.secondary)
			}

			Text(item.message)
				.font(.system(size: 12, weight: .regular, design: .monospaced))
				.foregroundColor(.primary)
				.lineLimit(3)
		}
		.padding(.vertical, 2)
	}
}

// MARK: - DebugLogDetailView

struct DebugLogDetailView: View {
	let item: DebugLogItem
	@Environment(\.dismiss) private var dismiss
	@State private var _copiedToast: Bool = false

	var body: some View {
		NBNavigationView(.localized("Log Detail"), displayMode: .inline) {
			List {
				Section {
					HStack {
						Text(.localized("Timestamp"))
						Spacer()
						Text(item.formattedFullDate)
							.font(.system(.footnote, design: .monospaced))
							.foregroundColor(.secondary)
					}

					HStack {
						Text(.localized("Level"))
						Spacer()
						HStack(spacing: 4) {
							Image(systemName: item.level.systemImage)
								.foregroundColor(item.level.color)
							Text(item.level.rawValue)
								.foregroundColor(item.level.color)
								.bold()
						}
					}

					HStack {
						Text(.localized("Category"))
						Spacer()
						Text(item.category)
							.foregroundColor(.secondary)
					}

					HStack {
						Text(.localized("Subsystem"))
						Spacer()
						Text(item.subsystem)
							.font(.system(.caption, design: .monospaced))
							.foregroundColor(.secondary)
							.lineLimit(1)
					}
				} header: {
					Text(.localized("Metadata"))
				}

				Section {
					Text(item.message)
						.font(.system(size: 13, weight: .regular, design: .monospaced))
						.textSelection(.enabled)
						.padding(.vertical, 4)
				} header: {
					Text(.localized("Message"))
				}

				Section {
					Button {
						UIPasteboard.general.string = item.message
						_showCopiedFeedback()
					} label: {
						Label(.localized("Copy Message"), systemImage: "doc.on.doc")
					}

					Button {
						UIPasteboard.general.string = item.exportText
						_showCopiedFeedback()
					} label: {
						Label(.localized("Copy Full Entry"), systemImage: "doc.on.clipboard")
					}

					Button {
						UIActivityViewController.show(activityItems: [item.exportText])
					} label: {
						Label(.localized("Share Entry"), systemImage: "square.and.arrow.up")
					}
				}
			}
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Button(.localized("Done")) {
						dismiss()
					}
				}
			}
			.overlay(alignment: .bottom) {
				if _copiedToast {
					Text(.localized("Copied to clipboard"))
						.font(.footnote.bold())
						.foregroundColor(.white)
						.padding(.horizontal, 16)
						.padding(.vertical, 8)
						.background(Color.black.opacity(0.8))
						.cornerRadius(20)
						.padding(.bottom, 20)
						.transition(.opacity.combined(with: .scale(scale: 0.9)))
				}
			}
			.animation(.easeInOut(duration: 0.2), value: _copiedToast)
		}
	}

	private func _showCopiedFeedback() {
		withAnimation { _copiedToast = true }
		DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
			withAnimation { _copiedToast = false }
		}
	}
}
