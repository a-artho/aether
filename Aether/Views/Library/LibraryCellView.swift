//
//  LibraryAppIconView.swift
//  Aether
//
//  Created by samara on 11.04.2025.
//

import SwiftUI
import NimbleExtensions
import NimbleViews
import UIKit

// MARK: - View
struct LibraryCellView: View {
	@Environment(\.horizontalSizeClass) private var horizontalSizeClass
	@Environment(\.editMode) private var editMode
	@ObservedObject private var installationManager = AppInstallationManager.shared

	private var _certificate: CertificatePair? {
		guard app.isSigned else { return nil }
		return Storage.shared.getCertificate(from: app)
	}

	var certInfo: Date.ExpirationInfo? {
		_certificate?.expiration?.expirationInfo()
	}
	
	var certRevoked: Bool {
		_certificate?.revoked == true
	}
	
	var app: AppInfoPresentable
	@Binding var selectedInfoAppPresenting: AnyApp?
	@Binding var selectedSigningAppPresenting: AnyApp?
	@Binding var selectedAppUUIDs: Set<String>
	
	private var _isQueued: Bool {
		installationManager.containsInstallation(for: app)
	}

	private var _installTitle: String {
		_isQueued ? .localized("Queued") : .localized("Install")
	}

	private func _installOrShowQueue(for app: AppInfoPresentable) {
		if installationManager.containsInstallation(for: app) {
			AppTabManager.shared.showInstallQueue()
		} else {
			installationManager.startInstall(app: app)
		}
	}

	// MARK: Selections
	private var _isSelected: Bool {
		guard let uuid = app.uuid else { return false }
		return selectedAppUUIDs.contains(uuid)
	}
	
	private func _toggleSelection() {
		guard let uuid = app.uuid else { return }
		if selectedAppUUIDs.contains(uuid) {
			selectedAppUUIDs.remove(uuid)
		} else {
			selectedAppUUIDs.insert(uuid)
		}
	}
	
	// MARK: Body
	var body: some View {
		let isRegular = horizontalSizeClass != .compact
		let isEditing = editMode?.wrappedValue == .active
		
		HStack(spacing: 18) {
			if isEditing {
				Button {
					_toggleSelection()
				} label: {
					Image(systemName: _isSelected ? "checkmark.circle.fill" : "circle")
						.foregroundColor(_isSelected ? .accentColor : .secondary)
						.font(.title2)
				}
				.buttonStyle(.borderless)
			}
			
			FRAppIconView(app: app, size: 50)
			
			_appDetails(for: app)
			
			if !isEditing {
				_buttonActions(for: app)
			}
		}
		.padding(isRegular ? 12 : 0)
		.background(
			isRegular
				? RoundedRectangle(cornerRadius: 18, style: .continuous)
				.fill(_isSelected && isEditing ? Color.accentColor.opacity(0.1) : Color(.quaternarySystemFill))
				: nil
		)
		.contentShape(Rectangle())
		.onTapGesture {
			if isEditing {
				_toggleSelection()
			}
		}
		.swipeActions {
			if !isEditing {
				_actions(for: app)
			}
		}
		.contextMenu {
			if !isEditing {
				_contextActions(for: app)
				Divider()
				_contextActionsExtra(for: app)
				Divider()
				_actions(for: app)
			}
		}
	}
	
}


// MARK: - Extension: View
extension LibraryCellView {
	private func _appDetails(for app: AppInfoPresentable) -> some View {
		let status = _certificateStatus
		return LibraryRowDetails(
			name: app.name ?? .localized("Unknown"),
			version: app.version ?? .localized("Unknown"),
			identifier: app.identifier,
			secondaryStatus: status?.label,
			signedColor: status?.color
		)
	}

	private var _certificateStatus: (label: String, color: Color)? {
		guard app.isSigned else { return nil }
		let cert = _certificate

		if cert?.revoked == true {
			return (.localized("Revoked"), .red)
		}

		if let info = cert?.expiration?.expirationInfo() {
			return (info.formatted, info.color)
		}

		return (.localized("Signed"), .green)
	}

	@ViewBuilder
	private func _actions(for app: AppInfoPresentable) -> some View {
		Button(.localized("Delete"), systemImage: "trash", role: .destructive) {
			if !Storage.shared.deleteApp(for: app) {
				UIAlertController.showAlertWithOk(title: .localized("App In Use"), message: .localized("Cancel its installation or update before deleting this app."))
			}
		}
	}
	
	@ViewBuilder
	private func _contextActions(for app: AppInfoPresentable) -> some View {
		Button(.localized("Get Info"), systemImage: "info.circle") {
			selectedInfoAppPresenting = AnyApp(base: app)
		}
	}
	
	@ViewBuilder
	private func _contextActionsExtra(for app: AppInfoPresentable) -> some View {
		if app.isSigned {
			if let id = app.identifier {
				Button(.localized("Open"), systemImage: "app.badge.checkmark") {
					UIApplication.openApp(with: id)
				}
			}
			Button(_installTitle, systemImage: "square.and.arrow.down") {
				_installOrShowQueue(for: app)
			}
			Button(.localized("Re-sign"), systemImage: "signature") {
				selectedSigningAppPresenting = AnyApp(base: app)
			}
			Button(.localized("Export"), systemImage: "square.and.arrow.up") {
				ExportManager.shared.startExport(app: app)
			}
		} else {
			Button(_installTitle, systemImage: "square.and.arrow.down") {
				_installOrShowQueue(for: app)
			}
			Button(.localized("Sign"), systemImage: "signature") {
				selectedSigningAppPresenting = AnyApp(base: app)
			}
		}
	}
	
	@ViewBuilder
	private func _buttonActions(for app: AppInfoPresentable) -> some View {
		let isSigning = installationManager.isSigningOrQueuedToSign(app)
		let title = isSigning ? String.localized("Signing") : (app.isSigned ? _installTitle : .localized("Sign"))
		Button {
			if app.isSigned {
				_installOrShowQueue(for: app)
				HapticManager.shared.selection()
			} else {
				selectedSigningAppPresenting = AnyApp(base: app)
			}
		} label: {
			NBButton(title, style: .text, isLoading: isSigning)
		}
		.buttonStyle(.borderless)
		.disabled(isSigning)
		.accessibilityLabel(title)
	}
}

/// Shared metadata hierarchy for Library apps and in-flight transfers.
struct LibraryRowDetails: View {
	let name: String
	let version: String?
	let identifier: String?
	var secondaryStatus: String? = nil
	var signedColor: Color? = nil
	var isFailed = false

	var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			HStack(spacing: 6) {
				if let signedColor {
					Circle()
						.fill(signedColor)
						.frame(width: 8, height: 8)
						.accessibilityHidden(true)
				}
				Text(name)
					.font(.headline)
					.foregroundStyle(.primary)
					.lineLimit(1)
			}

			Text(_secondLine)
				.font(.subheadline)
				.foregroundStyle(isFailed ? Color.red : Color.secondary)
				.lineLimit(isFailed ? 2 : 1)

			if let identifier, !identifier.isEmpty {
				Text(identifier)
					.font(.footnote)
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}
		}
		.padding(.vertical, 2)
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	private var _secondLine: String {
		[version, secondaryStatus]
			.compactMap { $0 }
			.filter { !$0.isEmpty }
			.joined(separator: " | ")
	}
}
