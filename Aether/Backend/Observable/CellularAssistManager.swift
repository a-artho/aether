//
//  CellularAssistManager.swift
//  Aether
//

import Combine
import Foundation
import NimbleExtensions
import UIKit

@MainActor
public final class CellularAssistManager: NSObject, ObservableObject, @preconcurrency UIDocumentInteractionControllerDelegate {
	public static let shared = CellularAssistManager()

	public enum State: Equatable {
		case idle
		case checkingSetup
		case installingHelper
		case waitingForDataOff
		case establishingTransport
		case waitingForManualRecovery
		case restoringData
		case verifying
		case failed(String)
	}

	private enum Command: String { case probe, off, on }
	private static let enabledKey = "Aether.cellularAssistEnabled"
	private static let restoreKey = "Aether.cellularAssistNeedsDataRestore"
	private static let helperName = "Aether Cellular"
	private static let helperVersion = "AETHER_CELLULAR_HELPER_V1"

	@Published public private(set) var isEnabled: Bool
	@Published public private(set) var state: State = .idle

	public var isBusy: Bool {
		switch state {
		case .checkingSetup, .installingHelper, .waitingForDataOff, .establishingTransport, .restoringData, .verifying:
			return true
		case .idle, .waitingForManualRecovery, .failed:
			return false
		}
	}

	/// The tunnel is still being kept alive while the user briefly cycles
	/// Mobile Data themselves. This is intentionally not "busy": they can turn
	/// Cellular Assist on from Settings while this message is on screen.
	public var isWaitingForManualRecovery: Bool {
		if case .waitingForManualRecovery = state { return true }
		return false
	}

	private var operationID: UUID?
	private var pendingSetup = false
	private var documentController: UIDocumentInteractionController?
	private var retryTask: Task<Void, Never>?
	private var didAttemptRestore = false

	private override init() {
		isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
		super.init()
	}

	public func requestEnabled(_ enabled: Bool) {
		guard enabled else {
			isEnabled = false
			UserDefaults.standard.set(false, forKey: Self.enabledKey)
			return
		}
		guard !isBusy else { return }
		guard _shortcutsAvailable() else {
			_showShortcutsRequired()
			return
		}
		pendingSetup = true
		state = .checkingSetup
		_startShortcut(.probe)
	}

	/// Called only after a real device transport failure. The existing tunnel is
	/// deliberately left running while the helper briefly changes Mobile Data.
	@discardableResult
	public func beginBootstrapIfPossible(cellularOnly: Bool, tunnelIsRunning: Bool) -> Bool {
		guard isEnabled, !isBusy, cellularOnly, tunnelIsRunning else { return false }
		guard _shortcutsAvailable() else {
			isEnabled = false
			UserDefaults.standard.set(false, forKey: Self.enabledKey)
			return false
		}

		didAttemptRestore = false
		state = .waitingForDataOff
		// `on` is idempotent. Persist this before asking Shortcuts to turn data
		// off so a future foreground launch can safely restore it after a crash.
		UserDefaults.standard.set(true, forKey: Self.restoreKey)
		_startShortcut(.off)
		return true
	}

	public func handleCallback(_ url: URL) {
		guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
		let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
			item.value.map { (item.name, $0) }
		})
		guard let rawID = values["operation"], let callbackID = UUID(uuidString: rawID), callbackID == operationID,
			let phase = values["phase"], let status = values["status"] else {
			_log("Ignored a stale or malformed shortcut callback.", level: .warning)
			return
		}

		if status != "success" {
			_handleShortcutFailure("The Cellular Assist shortcut did not finish.")
			return
		}

		switch phase {
		case Command.probe.rawValue:
			guard values["result"] == Self.helperVersion else {
				_installHelper()
				return
			}
			isEnabled = true
			UserDefaults.standard.set(true, forKey: Self.enabledKey)
			pendingSetup = false
			operationID = nil
			state = .idle
			_log("Cellular Assist helper verified.")
		case Command.off.rawValue:
			guard values["result"] == "\(Self.helperVersion)_OFF" else {
				_handleShortcutFailure("The Cellular Assist helper returned an invalid response.")
				return
			}
			state = .establishingTransport
			_retryTransportWhileDataIsOff()
		case Command.on.rawValue:
			guard values["result"] == "\(Self.helperVersion)_ON" else {
				_handleShortcutFailure("Mobile Data may still be off. Turn it back on in Control Center or Settings.")
				return
			}
			UserDefaults.standard.set(false, forKey: Self.restoreKey)
			didAttemptRestore = false
			operationID = nil
			state = .verifying
			Task { [weak self] in
				await DeviceConnectionManager.shared.reconcile(force: true)
				guard let self else { return }
				self.state = DeviceConnectionManager.shared.isConnected ? .idle : .failed("The device tunnel needs another retry.")
			}
		default:
			_log("Ignored an unknown shortcut callback phase.", level: .warning)
		}
	}

	public func handleApplicationDidBecomeActive() {
		if pendingSetup, !isBusy {
			requestEnabled(true)
			return
		}
		guard UserDefaults.standard.bool(forKey: Self.restoreKey), !isBusy else { return }
		state = .restoringData
		_startShortcut(.on)
	}

	public func cancelAndRestoreIfNeeded() {
		retryTask?.cancel()
		retryTask = nil
		operationID = nil
		didAttemptRestore = true
		guard UserDefaults.standard.bool(forKey: Self.restoreKey), _shortcutsAvailable() else {
			state = .idle
			return
		}
		state = .restoringData
		_startShortcut(.on)
	}

	/// Holds the in-app tunnel open and asks the Device tab to guide the user
	/// through a manual cellular reset when Cellular Assist is disabled.
	@discardableResult
	public func beginManualRecoveryIfNeeded(cellularOnly: Bool, tunnelIsRunning: Bool) -> Bool {
		guard cellularOnly, tunnelIsRunning, !isEnabled else { return false }
		guard !isBusy else { return true }
		state = .waitingForManualRecovery
		return true
	}

	public func connectionDidSucceed() {
		guard isWaitingForManualRecovery else { return }
		state = .idle
	}

	public func networkNoLongerNeedsManualRecovery() {
		guard isWaitingForManualRecovery else { return }
		state = .idle
	}

	private func _retryTransportWhileDataIsOff() {
		retryTask?.cancel()
		retryTask = Task { [weak self] in
			let delays: [UInt64] = [250_000_000, 500_000_000, 750_000_000, 1_000_000_000, 1_500_000_000]
			for delay in delays {
				try? await Task.sleep(nanoseconds: delay)
				guard !Task.isCancelled, let self, self.state == .establishingTransport else { return }
				await DeviceConnectionManager.shared.reconcile(force: true)
				if DeviceConnectionManager.shared.isConnected {
					self.state = .restoringData
					self._startShortcut(.on)
					return
				}
			}
			guard let self else { return }
			self.state = .restoringData
			self._startShortcut(.on)
			self._showFailure("The device tunnel could not be established.")
		}
	}

	private func _startShortcut(_ command: Command) {
		let id = UUID()
		operationID = id
		var callback = URLComponents()
		callback.scheme = "aether"
		callback.host = "cellular-assist"
		callback.queryItems = [
			URLQueryItem(name: "operation", value: id.uuidString),
			URLQueryItem(name: "phase", value: command.rawValue),
			URLQueryItem(name: "status", value: "success"),
		]
		var cancel = callback
		cancel.queryItems?.removeLast()
		cancel.queryItems?.append(URLQueryItem(name: "status", value: "cancel"))
		var error = callback
		error.queryItems?.removeLast()
		error.queryItems?.append(URLQueryItem(name: "status", value: "error"))

		guard let successURL = callback.url, let cancelURL = cancel.url, let errorURL = error.url else { return }
		var request = URLComponents(string: "shortcuts://x-callback-url/run-shortcut")!
		request.queryItems = [
			URLQueryItem(name: "name", value: Self.helperName),
			URLQueryItem(name: "input", value: "text"),
			URLQueryItem(name: "text", value: command.rawValue),
			URLQueryItem(name: "x-success", value: successURL.absoluteString),
			URLQueryItem(name: "x-cancel", value: cancelURL.absoluteString),
			URLQueryItem(name: "x-error", value: errorURL.absoluteString),
		]
		guard let url = request.url else { return }
		UIApplication.shared.open(url, options: [:]) { [weak self] opened in
			guard let self, !opened else { return }
			self._handleShortcutFailure("Aether could not open the Cellular Assist shortcut.")
		}
	}

	private func _installHelper() {
		operationID = nil
		state = .installingHelper
		guard let url = Bundle.main.url(forResource: Self.helperName, withExtension: "shortcut"),
			let presenter = UIApplication.topViewController() else {
			_handleShortcutFailure("The Cellular Assist helper is unavailable.")
			return
		}
		let controller = UIDocumentInteractionController(url: url)
		controller.delegate = self
		documentController = controller
		controller.presentOpenInMenu(from: presenter.view.bounds, in: presenter.view, animated: true)
	}

	public func documentInteractionControllerDidDismissOpenInMenu(_ controller: UIDocumentInteractionController) {
		documentController = nil
		if pendingSetup {
			state = .idle
		}
	}

	private func _shortcutsAvailable() -> Bool {
		URL(string: "shortcuts://").map { UIApplication.shared.canOpenURL($0) } ?? false
	}

	private func _showShortcutsRequired() {
		let action = UIAlertAction(title: "Download Shortcuts", style: .default) { _ in
			if let url = URL(string: "itms-apps://apps.apple.com/app/id1462947752") {
				UIApplication.shared.open(url)
			}
		}
		UIAlertController.showAlertWithCancel(title: "Shortcuts Required", message: "Cellular Assist uses Apple Shortcuts to briefly toggle Mobile Data.", actions: [action])
	}

	private func _handleShortcutFailure(_ message: String) {
		retryTask?.cancel()
		retryTask = nil
		operationID = nil
		if UserDefaults.standard.bool(forKey: Self.restoreKey), !didAttemptRestore, _shortcutsAvailable() {
			didAttemptRestore = true
			state = .restoringData
			_startShortcut(.on)
			return
		}
		if UserDefaults.standard.bool(forKey: Self.restoreKey) {
			state = .failed("Mobile Data may still be off. Turn it back on in Control Center or Settings.")
			_showFailure("Mobile Data may still be off. Turn it back on in Control Center or Settings.")
		} else {
			state = .failed(message)
			_showFailure(message)
		}
	}

	private func _showFailure(_ message: String) {
		UIAlertController.showAlertWithOk(title: "Cellular Assist", message: message)
	}

	private func _log(_ message: String, level: DebugLogItem.Level = .info) {
		DebugLogManager.shared.log(message, category: "Cellular Assist", level: level)
	}
}
