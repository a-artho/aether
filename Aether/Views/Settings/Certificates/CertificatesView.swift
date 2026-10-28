//
//  CertificatesView.swift
//  Aether
//
//  Created by samara on 15.04.2025.
//

import SwiftUI
import NimbleViews

// MARK: - View
struct CertificatesView: View {
	@AppStorage("aether.selectedCert") private var _storedSelectedCert: Int = 0
	@AppStorage("aether.selectedCertUUID") private var _selectedCertUUID: String = ""
	
	@State private var _isAddingPresenting = false
	@State private var _isRenamingPresenting = false
	@State private var _isSelectedInfoPresenting: CertificatePair?
	@State private var _certToRename: CertificatePair?
	@State private var _newNickname: String = ""

	// MARK: Fetch
	@FetchRequest(
		entity: CertificatePair.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)],
		animation: .snappy
	) private var _certificates: FetchedResults<CertificatePair>
	
	//
	private var _bindingSelectedCert: Binding<Int>?
	private var _selectedCertBinding: Binding<Int> {
		_bindingSelectedCert ?? $_storedSelectedCert
	}
	
	init(selectedCert: Binding<Int>? = nil) {
		self._bindingSelectedCert = selectedCert
	}
	
	// MARK: Body
	var body: some View {
		NBGrid {
			ForEach(Array(_certificates.enumerated()), id: \.element.uuid) { index, cert in
				_cellButton(for: cert, at: index)
			}
		}
		.aetherAmbientBackground(base: .grouped)
		.navigationTitle(.localized("Certificates"))
		.overlay {
			if _certificates.isEmpty {
				ContentUnavailableView {
					Label(.localized("No Certificates"), systemImage: "questionmark.folder.fill")
				} description: {
					Text(.localized("Get started signing by importing your first certificate."))
				} actions: {
					Button {
						_isAddingPresenting = true
					} label: {
						NBButton(.localized("Import"), style: .text)
					}
				}
			}
		}
		.toolbar {
			if _bindingSelectedCert == nil {
				NBToolbarButton(
					systemImage: "plus",
					style: .icon,
					placement: .topBarTrailing
				) {
					_isAddingPresenting = true
				}
			}
		}
		.sheet(item: $_isSelectedInfoPresenting) { cert in
			CertificatesInfoView(cert: cert)
		}
		.sheet(isPresented: $_isAddingPresenting) {
			CertificatesAddView()
				.presentationDetents([.medium])
		}
		.alert(.localized("Change Nickname"), isPresented: $_isRenamingPresenting, presenting: _certToRename) { cert in
			TextField(.localized("Nickname"), text: $_newNickname)
			Button(.localized("Cancel"), role: .cancel) { }
			Button(.localized("OK")) {
				cert.nickname = _newNickname.isEmpty ? nil : _newNickname
				Storage.shared.saveContext()
			}
		}
	}
}

// MARK: - View extension
extension CertificatesView {
	@ViewBuilder
	private func _cellButton(for cert: CertificatePair, at index: Int) -> some View {
		let cornerRadius = 28.0
		
		Button {
			_selectedCertBinding.wrappedValue = index
			if let uuid = cert.uuid {
				UserDefaults.standard.set(uuid, forKey: "aether.selectedCertUUID")
			}
		} label: {
			CertificatesCellView(
				cert: cert
			)
			.padding()
			.modifier(SettingsCardSurface(color: Color(uiColor: .quaternarySystemFill), cornerRadius: cornerRadius))
			.overlay(
				RoundedRectangle(cornerRadius: cornerRadius)
					.strokeBorder(
						_isSelected(cert, at: index) ? Color.accentColor : Color.clear,
						lineWidth: 2
					)
			)
			.contextMenu {
				_contextActions(for: cert)
				if cert.isDefault != true {
					Divider()
					_actions(for: cert)
				}
			}
			.animation(.spring(response: 0.25, dampingFraction: 0.7), value: _isSelected(cert, at: index))
		}
		.buttonStyle(.plain)
	}

	private func _isSelected(_ cert: CertificatePair, at index: Int) -> Bool {
		if !_selectedCertUUID.isEmpty, _certificates.contains(where: { $0.uuid == _selectedCertUUID }) {
			return cert.uuid == _selectedCertUUID
		}
		return _selectedCertBinding.wrappedValue == index
	}
	
	@ViewBuilder
	private func _actions(for cert: CertificatePair) -> some View {
		Button(.localized("Delete"), systemImage: "trash", role: .destructive) {
			if let uuid = cert.uuid, UserDefaults.standard.string(forKey: "aether.selectedCertUUID") == uuid {
				UserDefaults.standard.removeObject(forKey: "aether.selectedCertUUID")
			}
			Storage.shared.deleteCertificate(for: cert)
		}
	}
	
	@ViewBuilder
	private func _contextActions(for cert: CertificatePair) -> some View {
		Button(.localized("Get Info"), systemImage: "info.circle") {
			_isSelectedInfoPresenting = cert
		}
		Button(.localized("Change Nickname"), systemImage: "pencil") {
			_newNickname = cert.nickname ?? ""
			_certToRename = cert
			_isRenamingPresenting = true
		}
		Divider()
		Button(.localized("Check Revocation"), systemImage: "person.text.rectangle") {
			Storage.shared.revokagedCertificate(for: cert)
		}
	}
}
