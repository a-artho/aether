//
//  SigningView.swift
//  Aether
//
//  Created by samara on 14.04.2025.
//

import SwiftUI
import PhotosUI
import NimbleViews

// MARK: - View
struct SigningView: View {
	@Environment(\.dismiss) var dismiss
	@Environment(\.scenePhase) private var scenePhase
	@StateObject private var _optionsManager = OptionsManager.shared
	
	@State private var _temporaryOptions: Options = OptionsManager.shared.options
	@State private var _temporaryCertificate: Int
	@AppStorage("aether.selectedCertUUID") private var _selectedCertificateUUID = ""
	@State private var _profileIdentifier: String?
	@State private var _profileIdentityError: String?
	@State private var _isAether = false
	@State private var photoTask: Task<Void, Never>?
	@State private var photoGeneration = UUID()
	@State private var _isAltPickerPresenting = false
	@State private var _isFilePickerPresenting = false
	@State private var _isImagePickerPresenting = false
	@State private var _signingError: String?
	@State private var _selectedPhoto: PhotosPickerItem? = nil
	@State var appIcon: UIImage?
	
	// MARK: Fetch
	@FetchRequest(
		entity: CertificatePair.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)],
		animation: .snappy
	) private var certificates: FetchedResults<CertificatePair>
	
	private func _selectedCert() -> CertificatePair? {
		let storedUUID = _selectedCertificateUUID
		if !storedUUID.isEmpty, let match = certificates.first(where: { $0.uuid == storedUUID }) {
			return match
		}
		guard certificates.indices.contains(_temporaryCertificate) else { return nil }
		return certificates[_temporaryCertificate]
	}
	
	var app: AppInfoPresentable
	
	init(app: AppInfoPresentable) {
		self.app = app

		let storedCert = UserDefaults.standard.integer(forKey: "aether.selectedCert")
		__temporaryCertificate = State(initialValue: storedCert)
	}
		
	// MARK: Body
	var body: some View {
		NBNavigationView("", displayMode: .inline) {
			Form {
				_customizationOptions(for: app)
				_cert()
				_customizationProperties(for: app)
			}
			.safeAreaInset(edge: .bottom, spacing: 0) {
				_signingBottomBar
			}

			.toolbar {
				NBToolbarButton(role: .dismiss)
				ToolbarItem(placement: .principal) {
					Image("Glyph")
						.resizable()
						.scaledToFit()
						.frame(height: 38)
				}
				NBToolbarButton(
					.localized("Reset"),
					style: .text,
					placement: .topBarTrailing
				) {
					_temporaryOptions = OptionsManager.shared.options
					_temporaryOptions.matchAetherIdentityToProfile = nil
					photoTask?.cancel()
					photoGeneration = UUID()
					_selectedPhoto = nil
					appIcon = nil
				}
			}
			.sheet(isPresented: $_isAltPickerPresenting) { SigningAlternativeIconView(app: app, appIcon: $appIcon, isModifing: .constant(true)) }
			.sheet(isPresented: $_isFilePickerPresenting) {
				FileImporterRepresentableView(
					allowedContentTypes:  [.image],
					onDocumentsPicked: { urls in
						guard let selectedFileURL = urls.first else { return }
						photoTask?.cancel()
						photoGeneration = UUID()
						self.appIcon = UIImage.fromFile(selectedFileURL)?.resizeToSquare()
					}
				)
				.ignoresSafeArea()
			}
			.photosPicker(isPresented: $_isImagePickerPresenting, selection: $_selectedPhoto)
			.onChange(of: _selectedPhoto) { _, newValue in
				photoTask?.cancel()
				let generation = UUID()
				photoGeneration = generation
				guard let newValue else { return }
				photoTask = Task {
					if let data = try? await newValue.loadTransferable(type: Data.self),
					   let image = UIImage(data: data)?.resizeToSquare() {
						guard !Task.isCancelled, photoGeneration == generation else { return }
						appIcon = image
					}
				}
			}
		}
        .task(id: app.uuid) {
            let uuid = app.uuid
            let signed = app.isSigned
            let result = await Task.detached(priority: .userInitiated) {
                guard let uuid,
                    let path = FileManager.default.getPath(in: signed ? FileManager.default.signed(uuid) : FileManager.default.unsigned(uuid), for: "app"),
                    let info = NSDictionary(contentsOf: path.appendingPathComponent("Info.plist")) else { return false }
                return AetherSigningIdentity.isAether(info)
            }.value
            guard !Task.isCancelled else { return }
            _isAether = result
            _refreshProfileIdentity()
        }
        .onDisappear { photoTask?.cancel(); photoGeneration = UUID() }
        .onChange(of: _isAltPickerPresenting || _isFilePickerPresenting) { _, presented in
            if presented { photoTask?.cancel(); photoGeneration = UUID() }
        }
		.onChange(of: _selectedCertificateUUID) { _, _ in _refreshProfileIdentity() }
		.onChange(of: _temporaryCertificate) { _, _ in _refreshProfileIdentity() }
		.onChange(of: _temporaryOptions.matchAetherIdentityToProfile) { _, _ in _refreshProfileIdentity() }
		.alert(.localized("Error"), isPresented: Binding(
			get: { scenePhase == .active && _signingError != nil },
			set: { if !$0, scenePhase == .active { _signingError = nil } }
		)) {
			Button(.localized("Dismiss"), role: .cancel) { _signingError = nil }
		} message: { Text(_signingError ?? "") }
		.onAppear {
			let storedUUID = UserDefaults.standard.string(forKey: "aether.selectedCertUUID") ?? ""
			if !storedUUID.isEmpty, let idx = certificates.firstIndex(where: { $0.uuid == storedUUID }) {
				_temporaryCertificate = idx
			}
			
			_refreshProfileIdentity()

			// ppq protection
			if
				_optionsManager.options.ppqProtection,
				let identifier = app.identifier,
				let cert = _selectedCert(),
				cert.ppQCheck
			{
				_temporaryOptions.appIdentifier = "\(identifier).\(_optionsManager.options.ppqString)"
			}
			
			if
				let currentBundleId = app.identifier,
				let newBundleId = _temporaryOptions.identifiers[currentBundleId]
			{
				_temporaryOptions.appIdentifier = newBundleId
			}
			
			if
				let currentName = app.name,
				let newName = _temporaryOptions.displayNames[currentName]
			{
				_temporaryOptions.appName = newName
			}
		}
	}

}

// MARK: - Extension: View
extension SigningView {
	@ViewBuilder
	private var _signingBottomBar: some View {
		Button {
			_start()
		} label: {
			NBSheetButton(
				title: _temporaryOptions.post_installAppAfterSigned ? .localized("Sign and Install") : .localized("Start Signing"),
				style: .prominent
			)
		}
		.buttonStyle(.plain)
		.padding(.horizontal, 16)
		.padding(.vertical, 10)
		.frame(maxWidth: .infinity)
		.background {
			NBVariableBlurView()
				.rotationEffect(.degrees(180))
				.ignoresSafeArea(edges: .bottom)
				.allowsHitTesting(false)
		}
	}

	@ViewBuilder
	private func _customizationOptions(for app: AppInfoPresentable) -> some View {
		NBSection(.localized("Customization")) {
			Menu {
				Button(.localized("Select Alternative Icon"), systemImage: "app.dashed") { _isAltPickerPresenting = true }
				Button(.localized("Choose from Files"), systemImage: "folder") { _isFilePickerPresenting = true }
				Button(.localized("Choose from Photos"), systemImage: "photo") { _isImagePickerPresenting = true }
			} label: {
				if let icon = appIcon {
					Image(uiImage: icon)
						.appIconStyle()
				} else {
					FRAppIconView(app: app, size: 50)
				}
			}
			
			_infoCell(.localized("Name"), desc: _temporaryOptions.appName ?? app.name) {
				SigningPropertiesView(
					title: .localized("Name"),
					initialValue: _temporaryOptions.appName ?? (app.name ?? ""),
					bindingValue: $_temporaryOptions.appName
				)
			}
			_infoCell(.localized("Identifier"), desc: _temporaryOptions.matchAetherIdentityToProfile == true ? (_profileIdentifier ?? .localized("Unavailable")) : (_temporaryOptions.appIdentifier ?? app.identifier)) {
				SigningPropertiesView(
					title: .localized("Identifier"),
					initialValue: _temporaryOptions.appIdentifier ?? (app.identifier ?? ""),
					bindingValue: $_temporaryOptions.appIdentifier
				)
			}
			.disabled(_temporaryOptions.matchAetherIdentityToProfile == true)
			_infoCell(.localized("Version"), desc: _temporaryOptions.appVersion ?? app.version) {
				SigningPropertiesView(
					title: .localized("Version"),
					initialValue: _temporaryOptions.appVersion ?? (app.version ?? ""),
					bindingValue: $_temporaryOptions.appVersion
				)
			}
		}
	}
	
	@ViewBuilder
	private func _cert() -> some View {
		NBSection(.localized("Signing")) {
			if let cert = _selectedCert() {
				NavigationLink {
					CertificatesView(selectedCert: $_temporaryCertificate)
				} label: {
					CertificatesCellView(
						cert: cert
					)
				}
			} else {
				Text(.localized("No Certificate"))
					.font(.footnote)
					.foregroundColor(.disabled())
			}
			if _isAether {
				Toggle(.localized("Match Certificate Identity"), isOn: Binding(
					get: { _temporaryOptions.matchAetherIdentityToProfile == true },
					set: { _temporaryOptions.matchAetherIdentityToProfile = $0 }
				))
				if _temporaryOptions.matchAetherIdentityToProfile == true {
					Text(_profileIdentityError ?? _profileIdentifier ?? .localized("No Certificate"))
						.font(.footnote)
						.foregroundStyle(.secondary)
				}
			}
		} footer: {
			if _isAether {
				Text(.localized("Match Aether’s bundle identifier and background task declarations to the selected profile. Keeps callback schemes and existing VPN extension signing. Changing identity may create a separate installation with new data and notification permissions."))
			}
		}
	}
	
	@ViewBuilder
	private func _customizationProperties(for app: AppInfoPresentable) -> some View {
		NBSection(.localized("Advanced")) {
			DisclosureGroup(.localized("Modify")) {
				NavigationLink(.localized("Existing Dylibs")) {
					SigningDylibView(
						app: app,
						options: $_temporaryOptions.optional()
					)
				}
				
				NavigationLink(.localized("Frameworks & PlugIns")) {
					SigningFrameworksView(
						app: app,
						options: $_temporaryOptions.optional()
					)
				}
			
				NavigationLink(.localized("Entitlements") + " (BETA)") {
					SigningEntitlementsView(
						bindingValue: $_temporaryOptions.appEntitlementsFile
					)
				}
				
				NavigationLink(.localized("Tweaks")) {
					SigningTweaksView(
						options: $_temporaryOptions
					)
				}
			}
			
			NavigationLink(.localized("Properties")) {
				Form { SigningOptionsView(
					options: $_temporaryOptions,
					temporaryOptions: _optionsManager.options
				)}
				.navigationTitle(.localized("Properties"))
			}
		}
	}
	
	@ViewBuilder
	private func _infoCell<V: View>(_ title: String, desc: String?, @ViewBuilder destination: () -> V) -> some View {
		NavigationLink {
			destination()
		} label: {
			LabeledContent(title) {
				Text(desc ?? .localized("Unknown"))
		}
	}
}

}

// MARK: - Extension: View (import)
extension SigningView {
	private func _refreshProfileIdentity() {
		_profileIdentifier = nil
		_profileIdentityError = nil
		guard _temporaryOptions.matchAetherIdentityToProfile == true else { return }
		do { _profileIdentifier = try _resolveProfileIdentity() }
		catch { _profileIdentityError = error.localizedDescription }
	}

	private func _resolveProfileIdentity() throws -> String {
		guard let certificate = SigningCertificateSnapshot(_selectedCert()),
			let profile = CertificateReader(certificate.provisionURL).decoded else {
			throw AetherSigningIdentity.Failure.invalidProfile
		}
		guard profile.ExpirationDate > Date() else { throw AetherSigningIdentity.Failure.expiredProfile }
		return try AetherSigningIdentity.bundleIdentifier(
			applicationIdentifier: profile.Entitlements?["application-identifier"]?.value as? String
		)
	}

	private func _start() {
		guard
			_selectedCert() != nil || _temporaryOptions.signingOption != .default
		else {
			UIAlertController.showAlertWithOk(
				title: .localized("No Certificate"),
				message: .localized("Please go to settings and import a valid certificate"),
				isCancel: true
			)
			return
		}

		var options = _temporaryOptions
		if options.matchAetherIdentityToProfile == true {
			do {
				guard _isAether else { throw AetherSigningIdentity.Failure.notAether }
				try AetherSigningIdentity.validateOptions(
					signingWithCertificate: options.signingOption == .default && _selectedCert() != nil,
					customEntitlements: options.appEntitlementsFile != nil,
					mergeEntitlements: options.mergeEntitlements,
					removeURLScheme: options.removeURLScheme,
					removeProvisioning: options.removeProvisioning
				)
				options.appIdentifier = try _resolveProfileIdentity()
			} catch {
				_signingError = error.localizedDescription
				return
			}
		}
		HapticManager.shared.impact()
		
		if AppInstallationManager.shared.startSigning(
			app: app,
			options: options,
			icon: appIcon,
			certificate: _selectedCert()
		) { dismiss() }
		else { _signingError = .localized("This app is already queued.") }
	}
}
