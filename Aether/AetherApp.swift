//
//  AetherApp.swift
//  Aether
//
//  Created by samara on 10.04.2025.
//

import SwiftUI
import Nuke
import IDeviceSwift
import NimbleExtensions
import OSLog
import UserNotifications

@main
struct AetherApp: App {
	@UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
	@StateObject private var installedApps = InstalledAppsStore.shared
	@ObservedObject private var deviceConnection = DeviceConnectionManager.shared

	let heartbeat = HeartbeatManager.shared

	let storage = Storage.shared

	var body: some Scene {
		WindowGroup {
			VariedTabbarView()
				.environment(\.managedObjectContext, storage.context)
				.onOpenURL(perform: _handleURL)
				.onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
					DebugLogManager.shared.log("Aether became active; awaiting any system file handoff.", category: "Import", level: .debug)
				}
				.task(id: deviceConnection.isConnected) {
					if deviceConnection.isConnected {
						await installedApps.load()
					} else {
						installedApps.clear()
					}
				}
				.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Aether.installedAppsRefresh"))) { _ in
					Task {
						guard deviceConnection.isConnected else { return }
						await installedApps.refresh(force: true)
					}
				}
				.onReceive(NotificationCenter.default.publisher(for: .heartbeat)) { _ in
					Task { await deviceConnection.reconcile() }
				}
				.onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
					Task { await installedApps.refreshOnForeground() }
				}
			.onReceive(NotificationCenter.default.publisher(for: .heartbeatInvalidHost)) { _ in
				DispatchQueue.main.async {
					UIAlertController.showAlertWithOk(
						title: "InvalidHostID",
						message: .localized("Your pairing file is invalid and is incompatible with your device, please import a valid pairing file.")
					)
				}
			}
			// dear god help me
			.onAppear {
				if let style = UIUserInterfaceStyle(rawValue: UserDefaults.standard.integer(forKey: "Aether.userInterfaceStyle")) {
					UIApplication.topViewController()?.view.window?.overrideUserInterfaceStyle = style
				}

				UIApplication.topViewController()?.view.window?.tintColor = UIColor(Color(hex: UserDefaults.standard.string(forKey: "Aether.userTintColor") ?? "#848ef9"))
			}
		}
	}

	private func _handleURL(_ url: URL) {
		DebugLogManager.shared.log("URL handoff received: scheme=\(url.scheme ?? "none"), file=\(url.isFileURL), extension=\(url.pathExtension.lowercased()), appState=\(UIApplication.shared.applicationState.rawValue).", category: "Import")
		if url.scheme == "aether" {
			if url.host == "cellular-assist" {
				CellularAssistManager.shared.handleCallback(url)
				return
			}
			if url.host == "tab" {
				guard
					let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
					let queryItems = components.queryItems,
					let tabName = queryItems.first(where: { $0.name == "name" })?.value,
					let tab = TabEnum(rawValue: tabName)
				else {
					return
				}
				AppTabManager.shared.switchTo(tab)
				return
			}
			if url.host == "open-settings" {
				var requestedPage: AppTabManager.SettingsPage? = nil
				if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
				   let pageParam = components.queryItems?.first(where: { $0.name == "page" })?.value {
					requestedPage = AppTabManager.SettingsPage(rawValue: pageParam)
				}
				AppTabManager.shared.openSettings(page: requestedPage)
				return
			}
			if url.host == "open-installation-settings" {
				AppTabManager.shared.openInstallationSettings()
				return
			}
			if url.host == "open-on-device-pairing" {
				if OnDevicePairingManager.isSupported {
					OnDevicePairingManager.shared.begin()
				}
				AppTabManager.shared.openSettings(page: .pairingFile)
				return
			}
			if url.host == "open-search" {
				AppTabManager.shared.openSearch()
				return
			}
			if url.host == "close-search" {
				AppTabManager.shared.closeSearch()
				return
			}
			if url.host == "open-all-repos" {
				AppTabManager.shared.switchTo(.sources)
				SourcesRouter.shared.requestNavigation(.allRepos)
				return
			}
			if url.host == "open-first-source" {
				AppTabManager.shared.switchTo(.sources)
				SourcesRouter.shared.requestNavigation(.firstSource)
				return
			}
			if url.host == "open-source" {
				AppTabManager.shared.switchTo(.sources)
				let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
				let name = components?.queryItems?.first(where: { $0.name == "name" })?.value
				SourcesRouter.shared.requestNavigation(.source(name: name))
				return
			}
			if url.host == "open-app" {
				AppTabManager.shared.switchTo(.sources)
				let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
				let appName = components?.queryItems?.first(where: { $0.name == "name" })?.value
				let sourceName = components?.queryItems?.first(where: { $0.name == "source" })?.value
				SourcesRouter.shared.requestNavigation(
					.app(sourceName: sourceName, appName: appName)
				)
				return
			}
			if url.host == "open-add-source" {
				AppTabManager.shared.switchTo(.sources)
				let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
				let prepopulateURL = components?.queryItems?.first(where: { $0.name == "url" })?.value ?? ""
				SourcesRouter.shared.presentAddSource(initialURL: prepopulateURL)
				return
			}
			#if DEBUG
			if url.host == "trigger-save-source" {
				NotificationCenter.default.post(name: Notification.Name("Aether.triggerSaveSource"), object: nil)
				return
			}
			if url.host == "test-scroll" {
				AppTabManager.shared.switchTo(.installed)
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
					NotificationCenter.default.post(name: Notification.Name("Aether.testScrollDevice"), object: nil)
				}
				return
			}
			if url.host == "mock-apps" {
				NotificationCenter.default.post(name: Notification.Name("Aether.mockApps"), object: nil)
				AppTabManager.shared.switchTo(.installed)
				return
			}
			if url.host == "clear-apps" {
				NotificationCenter.default.post(name: Notification.Name("Aether.clearApps"), object: nil)
				AppTabManager.shared.switchTo(.installed)
				return
			}
			if url.host == "open-app-detail" {
				AppTabManager.shared.switchTo(.installed)
				let bundleId = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
					NotificationCenter.default.post(name: Notification.Name("Aether.openAppDetail"), object: bundleId)
				}
				return
			}
			if url.host == "scroll-detail-bottom" {
				NotificationCenter.default.post(name: Notification.Name("Aether.scrollDetailToBottom"), object: nil)
				return
			}
			if url.host == "mock-install" {
				AppInstallationManager.shared.startMockInstall(progress: 0.62, status: .installing)
				AppTabManager.shared.switchTo(.installed)
				return
			}
			if url.host == "mock-install-queue" {
				let manager = AppInstallationManager.shared
				manager.startMockInstall(progress: 0.62)
				manager.enqueueMockInstall(name: "Apollo", identifier: "com.christianselig.Apollo")
				manager.enqueueMockInstall(name: "RetroArch", identifier: "com.libretro.RetroArch")
				return
			}
			if url.host == "mock-install-complete-current" {
				AppInstallationManager.shared.viewModel?.status = .completed(.success(()))
				return
			}
			if url.host == "mock-install-fail-current" {
				AppInstallationManager.shared.viewModel?.status = .broken(NSError(domain: "QueueVerification", code: 1, userInfo: [NSLocalizedDescriptionKey: "Test installation failure"]))
				return
			}
			if url.host == "mock-install-done" {
				AppInstallationManager.shared.startMockInstall(progress: 1.0, status: .completed(.success(())))
				AppTabManager.shared.switchTo(.installed)
				return
			}
			#endif
			/// aether://import-certificate?p12=<base64>&mobileprovision=<base64>&password=<base64>
			if url.host == "import-certificate" {
				guard
					let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
					let queryItems = components.queryItems
				else {
					return
				}

				func queryValue(_ name: String) -> String? {
					queryItems.first(where: { $0.name == name })?.value?.removingPercentEncoding
				}

				guard
					let p12Base64 = queryValue("p12"),
					let provisionBase64 = queryValue("mobileprovision"),
					let passwordBase64 = queryValue("password"),
					let passwordData = Data(base64Encoded: passwordBase64),
					let password = String(data: passwordData, encoding: .utf8)
				else {
					return
				}

				let generator = UINotificationFeedbackGenerator()
				generator.prepare()

				guard
					let p12URL = FileManager.default.decodeAndWrite(base64: p12Base64, pathComponent: ".p12"),
					let provisionURL = FileManager.default.decodeAndWrite(base64: provisionBase64, pathComponent: ".mobileprovision"),
					FR.checkPasswordForCertificate(for: p12URL, with: password, using: provisionURL)
				else {
					generator.notificationOccurred(.error)
					return
				}

				FR.handleCertificateFiles(
					p12URL: p12URL,
					provisionURL: provisionURL,
					p12Password: password
				) { error in
					if let error = error {
						UIAlertController.showAlertWithOk(title: .localized("Error"), message: error.localizedDescription)
					} else {
						generator.notificationOccurred(.success)
					}
				}

				return
			}
			/// aether://export-certificate?callback_template=<template>
			/// ?callback_template=: This is how we callback to the application requesting the certificate, this will be a url scheme
			/// 	example: livecontainer%3A%2F%2Fcertificate%3Fcert%3D%24%28BASE64_CERT%29%26password%3D%24%28PASSWORD%29
			/// 	decoded: livecontainer://certificate?cert=$(BASE64_CERT)&password=$(PASSWORD)
			/// $(BASE64_CERT) and $(PASSWORD) must be presenting in the callback template so we can replace them with the proper content
			if url.host == "export-certificate" {
				guard
					let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
				else {
					return
				}

				let queryItems = components.queryItems?.reduce(into: [String: String]()) { $0[$1.name.lowercased()] = $1.value } ?? [:]
				guard let callbackTemplate = queryItems["callback_template"]?.removingPercentEncoding else { return }

				FR.exportCertificateAndOpenUrl(using: callbackTemplate)
			}
			/// aether://source/<url>
			if let fullPath = url.validatedScheme(after: "/source/") {
				FR.handleSource(fullPath)
			}
			/// aether://install/<url.ipa>
			if
				let fullPath = url.validatedScheme(after: "/install/"),
				let downloadURL = URL(string: fullPath)
			{
				UIAlertController.showAlertWithCancel(
					title: .localized("Install"),
					message: .localized("Do you want to download and install this file?") + "\n\n\(downloadURL)",
					actions: [
						UIAlertAction(title: .localized("Install"), style: .default) { _ in
							Task { _ = await DownloadManager.shared.startDownload(from: downloadURL) }
						}
					]
				)
			}
		} else {
			let pathExtension = url.pathExtension.lowercased()
			if pathExtension == "ipa" || pathExtension == "tipa" {
				_importExternalPackage(from: url)
				return
			}
			if url.isFileURL {
				_reportExternalImportError(ExternalFileMaterializationError.unsupportedFileType)
			}
		}
	}

	private func _reportExternalImportError(_ error: Error) {
		let detail = error as NSError
		DebugLogManager.shared.log("External import failed: domain=\(detail.domain), code=\(detail.code), \(detail.localizedDescription)", category: "Import", level: .error)
	}

	private func _importExternalPackage(from externalURL: URL) {
		AppTabManager.shared.closeSearch()
		AppTabManager.shared.switchTo(.library)
		let importID = UUID().uuidString
		DebugLogManager.shared.log("[\(importID)] External package received: \(externalURL.lastPathComponent); inbox=\(externalURL.path.contains("/Inbox/")), appState=\(UIApplication.shared.applicationState.rawValue).", category: "Import")
		Task.detached(priority: .utility) {
			do {
				let materializedFile = try FileManager.default.materializePackageForImport(
					at: externalURL,
					diagnostics: { message in
						DispatchQueue.main.async {
							DebugLogManager.shared.log("[\(importID)] \(message)", category: "Import")
						}
					}
				)
				await MainActor.run {
					DebugLogManager.shared.log("[\(importID)] External package copied; handing off to Library processing.", category: "Import")
					let download = DownloadManager.shared.startArchive(
						from: materializedFile.fileURL,
						id: "AetherManualDownload_\(importID)",
						sourceCleanup: { materializedFile.cleanup() }
					)
					DownloadManager.shared.retryProcessing(download)
				}
			} catch {
				await MainActor.run {
					_reportExternalImportError(error)
				}
			}
		}
	}
}

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
	func application(
		_ application: UIApplication,
		didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
	) -> Bool {
		UNUserNotificationCenter.current().delegate = self
		DebugLogManager.shared.log("App launched: bundle=\(Bundle.main.bundleIdentifier ?? "unknown"), version=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "unknown"), launchURL=\(launchOptions?[.url] != nil).", category: "Import", level: .debug)
		_createPipeline()
		_createDocumentsDirectories()
		ResetView.clearWorkCache()
		DownloadManager.shared.prepareForBackgroundEvents()
		_addDefaultCertificates()
		return true
	}

	func application(
		_ application: UIApplication,
		handleEventsForBackgroundURLSession identifier: String,
		completionHandler: @escaping () -> Void
	) {
		guard identifier == DownloadManager.backgroundSessionIdentifier else {
			completionHandler()
			return
		}

		DownloadManager.shared.setBackgroundEventsCompletionHandler(completionHandler)
	}

	func userNotificationCenter(
		_ center: UNUserNotificationCenter,
		didReceive response: UNNotificationResponse
	) async {
		guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
			response.notification.request.identifier.hasPrefix("Aether.download.result.") else { return }
		await MainActor.run {
			AppTabManager.shared.switchTo(.library)
		}
	}

	private func _createPipeline() {
		DataLoader.sharedUrlCache.diskCapacity = 0

		let pipeline = ImagePipeline {
			let dataLoader: DataLoader = {
				let config = URLSessionConfiguration.default
				config.urlCache = nil
				return DataLoader(configuration: config)
			}()
			let dataCache = try? DataCache(name: "com.anfear.aether.datacache") // disk cache
			let imageCache = Nuke.ImageCache() // memory cache
			dataCache?.sizeLimit = 500 * 1024 * 1024
			imageCache.costLimit = 48 * 1024 * 1024
			$0.dataCache = dataCache
			$0.imageCache = imageCache
			$0.dataLoader = dataLoader
			$0.dataCachePolicy = .automatic
			$0.isStoringPreviewsInMemoryCache = false
		}

		ImagePipeline.shared = pipeline
	}

	private func _createDocumentsDirectories() {
		let fileManager = FileManager.default

		let directories: [URL] = [
			fileManager.archives,
			fileManager.certificates,
			fileManager.signed,
			fileManager.unsigned
		]

		for url in directories {
			try? fileManager.createDirectoryIfNeeded(at: url)
		}
	}

	private func _addDefaultCertificates() {
		guard !UserDefaults.standard.bool(forKey: "aether.didImportDefaultCertificates.v2"),
			let assets = Bundle.main.url(forResource: "signing-assets", withExtension: nil) else { return }
		Task { @MainActor in
			do {
				let folders = try FileManager.default.contentsOfDirectory(at: assets, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
				var allSucceeded = true
				for folder in folders where folder.hasDirectoryPath {
					do {
						let key = folder.appendingPathComponent("cert.p12")
						let provision = folder.appendingPathComponent("cert.mobileprovision")
						let password = try String(contentsOf: folder.appendingPathComponent("cert.txt"), encoding: .utf8)
						let keyData = try Data(contentsOf: key)
						let provisionData = try Data(contentsOf: provision)
						// Avoid duplicates if first-run import is interrupted after a
						// certificate commit but before the completion flag is saved.
						let exists = Storage.shared.getAllCertificates().contains { cert in
							guard cert.isDefault, cert.password == password,
								let storedKey = Storage.shared.getFile(.certificate, from: cert),
								let storedProvision = Storage.shared.getFile(.provision, from: cert) else { return false }
							return (try? Data(contentsOf: storedKey)) == keyData && (try? Data(contentsOf: storedProvision)) == provisionData
						}
						if exists { continue }
						let _: Void = try await withCheckedThrowingContinuation { continuation in
							FR.handleCertificateFiles(p12URL: key, provisionURL: provision, p12Password: password,
								certificateName: folder.lastPathComponent, isDefault: true) { error in
								if let error { continuation.resume(throwing: error) }
								else { continuation.resume() }
							}
						}
					} catch {
						allSucceeded = false
						DebugLogManager.shared.log("Default certificate import failed: \(error.localizedDescription)", category: "Certificate", level: .error)
					}
				}
				if allSucceeded { UserDefaults.standard.set(true, forKey: "aether.didImportDefaultCertificates.v2") }
			} catch {
				DebugLogManager.shared.log("Default certificate import failed: \(error.localizedDescription)", category: "Certificate", level: .error)
			}
		}
	}

}
