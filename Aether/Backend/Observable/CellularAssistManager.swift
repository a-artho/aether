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
		case failed(String)
	}

	private enum Command: String { case probe, off, on }
	/// A Cellular Assist cycle deliberately gets one automatic opportunity to
	/// change Mobile Data. Network callbacks are noisy while that happens, so a
	/// completed or failed cycle stays consumed until a new recovery opportunity
	/// begins, such as an explicit Local reconnect or leaving cellular-only
	/// networking.
	private enum AutomaticRecoveryEpisode {
		case armed
		case active
		case consumed
	}
	private enum HelperProbePurpose: Equatable {
		case initial
		case postInstall
	}

	private enum HelperSetupPhase: Equatable {
		case idle
		case probing(HelperProbePurpose)
		case presentingInstaller
		case waitingForPostInstallVerification
	}
	private static let enabledKey = "Aether.cellularAssistEnabled"
	private static let restoreKey = "Aether.cellularAssistNeedsDataRestore"
	private static let helperName = "Aether Cellular"
	private static let helperVersion = "AETHER_CELLULAR_HELPER_V1"

	@Published public private(set) var isEnabled: Bool
	@Published public private(set) var state: State = .idle

	public var isBusy: Bool {
		switch state {
		case .checkingSetup, .installingHelper, .waitingForDataOff, .establishingTransport, .restoringData:
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

	/// Lets DeviceConnectionManager ignore ordinary path-change reconciliations
	/// while this manager owns the temporary Mobile Data transition.
	public var isAutomaticRecoveryInProgress: Bool {
		automaticRecoveryEpisode == .active
	}

	private var operationID: UUID?
	private var helperSetupPhase: HelperSetupPhase = .idle
	private var documentController: UIDocumentInteractionController?
	private var retryTask: Task<Void, Never>?
	private var didAttemptRestore = false
	private var didShowMissingShortcutsNotice = false
	private var automaticRecoveryEpisode: AutomaticRecoveryEpisode = .armed

	private override init() {
		isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
		super.init()
	}

	public func requestEnabled(_ enabled: Bool) {
		guard enabled else {
			helperSetupPhase = .idle
			isEnabled = false
			UserDefaults.standard.set(false, forKey: Self.enabledKey)
			return
		}
		guard !isBusy else { return }
		guard _shortcutsAvailable() else {
			_disableForMissingShortcuts()
			return
		}
		automaticRecoveryEpisode = .armed
		helperSetupPhase = .probing(.initial)
		state = .checkingSetup
		_startShortcut(.probe)
	}

	/// Called only after a real device transport failure. The existing tunnel is
	/// deliberately left running while the helper briefly changes Mobile Data.
	@discardableResult
	public func beginBootstrapIfPossible(cellularOnly: Bool, tunnelIsRunning: Bool) -> Bool {
		guard isEnabled, !isBusy, cellularOnly, tunnelIsRunning,
			automaticRecoveryEpisode == .armed else { return false }
		guard _shortcutsAvailable() else {
			_disableForMissingShortcuts()
			return false
		}

		automaticRecoveryEpisode = .active
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

		if status == "cancel" {
			_handleShortcutCancel(phase: phase)
			return
		}

		if status != "success" {
			let message = values["errorMessage"] ?? "The Cellular Assist shortcut did not finish."
			if phase == Command.probe.rawValue,
				case let .probing(purpose) = helperSetupPhase {
				_handleHelperProbeFailure(message, purpose: purpose)
				return
			}
			_handleShortcutFailure(message, phase: phase)
			return
		}

		switch phase {
		case Command.probe.rawValue:
			guard case let .probing(purpose) = helperSetupPhase else {
				_log("Ignored a shortcut probe outside helper setup.", level: .warning)
				return
			}
			guard values["result"] == Self.helperVersion else {
				_handleHelperProbeFailure(
					"The Cellular Assist helper could not be verified.",
					purpose: purpose
				)
				return
			}
			isEnabled = true
			UserDefaults.standard.set(true, forKey: Self.enabledKey)
			helperSetupPhase = .idle
			operationID = nil
			state = .idle
			_log("Cellular Assist helper verified.")
		case Command.off.rawValue:
			guard values["result"] == "\(Self.helperVersion)_OFF" else {
				_handleShortcutFailure("The Cellular Assist helper returned an invalid response.", phase: phase)
				return
			}
			state = .establishingTransport
			_retryTransportWhileDataIsOff()
		case Command.on.rawValue:
			guard values["result"] == "\(Self.helperVersion)_ON" else {
				_handleShortcutFailure("Mobile Data may still be off. Turn it back on in Control Center or Settings.", phase: phase)
				return
			}
			UserDefaults.standard.set(false, forKey: Self.restoreKey)
			operationID = nil
			automaticRecoveryEpisode = .consumed
			state = .idle
			_log("Cellular Assist restored Mobile Data after the device tunnel connected.")
		default:
			_log("Ignored an unknown shortcut callback phase.", level: .warning)
		}
	}

	public func handleApplicationDidBecomeActive() {
		if helperSetupPhase == .waitingForPostInstallVerification {
			helperSetupPhase = .probing(.postInstall)
			state = .checkingSetup
			_startShortcut(.probe)
			return
		}
		guard UserDefaults.standard.bool(forKey: Self.restoreKey), !isBusy, !didAttemptRestore else { return }
		guard _shortcutsAvailable() else {
			_disableForMissingShortcuts()
			return
		}
		_restoreMobileDataOnce()
	}

	public func cancelAndRestoreIfNeeded() {
		retryTask?.cancel()
		retryTask = nil
		operationID = nil
		guard UserDefaults.standard.bool(forKey: Self.restoreKey) else {
			state = .idle
			return
		}
		guard _shortcutsAvailable() else {
			_disableForMissingShortcuts()
			return
		}
		_restoreMobileDataOnce(force: true)
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
		if isWaitingForManualRecovery {
			state = .idle
		}
	}

	/// Re-arm only for an explicit Local-mode reconnect. Ordinary NWPath events
	/// must not restart a just-finished Cellular Assist cycle.
	public func rearmAutomaticRecovery() {
		guard automaticRecoveryEpisode != .active else { return }
		automaticRecoveryEpisode = .armed
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
				await DeviceConnectionManager.shared.reconcile(force: true, cellularAssistTransaction: true)
				if DeviceConnectionManager.shared.isConnected {
					self._restoreMobileDataOnce()
					return
				}
			}
			guard let self else { return }
			self._restoreMobileDataOnce()
			self._showFailure("The device tunnel could not be established.")
		}
	}

	private func _startShortcut(_ command: Command) {
		guard _shortcutsAvailable() else {
			_disableForMissingShortcuts()
			return
		}
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
			if command == .probe, case let .probing(purpose) = self.helperSetupPhase {
				self._handleHelperProbeFailure(
					"Aether could not open the Cellular Assist shortcut.",
					purpose: purpose
				)
				return
			}
			self._handleShortcutFailure("Aether could not open the Cellular Assist shortcut.", phase: command.rawValue)
		}
	}

	private func _installHelper() {
		operationID = nil
		helperSetupPhase = .presentingInstaller
		state = .installingHelper
		guard let url = Bundle.main.url(forResource: Self.helperName, withExtension: "shortcut"),
			let presenter = UIApplication.topViewController() else {
			_handleShortcutFailure("The Cellular Assist helper is unavailable.", phase: Command.probe.rawValue)
			return
		}
		let controller = UIDocumentInteractionController(url: url)
		controller.delegate = self
		documentController = controller
		controller.presentOpenInMenu(from: presenter.view.bounds, in: presenter.view, animated: true)
	}

	public func documentInteractionController(_ controller: UIDocumentInteractionController, willBeginSendingToApplication application: String?) {
		if helperSetupPhase == .presentingInstaller {
			helperSetupPhase = .waitingForPostInstallVerification
		}
	}

	public func documentInteractionControllerDidDismissOpenInMenu(_ controller: UIDocumentInteractionController) {
		documentController = nil
		if helperSetupPhase == .presentingInstaller {
			_cancelHelperSetup()
		}
	}

	private func _shortcutsAvailable() -> Bool {
		let isAvailable = URL(string: "shortcuts://").map { UIApplication.shared.canOpenURL($0) } ?? false
		if isAvailable {
			didShowMissingShortcutsNotice = false
		}
		return isAvailable
	}

	private func _disableForMissingShortcuts() {
		retryTask?.cancel()
		retryTask = nil
		operationID = nil
		helperSetupPhase = .idle
		didAttemptRestore = false
		automaticRecoveryEpisode = .consumed
		isEnabled = false
		UserDefaults.standard.set(false, forKey: Self.enabledKey)
		UserDefaults.standard.set(false, forKey: Self.restoreKey)
		state = .idle

		guard !didShowMissingShortcutsNotice else { return }
		didShowMissingShortcutsNotice = true
		_showFailure("Cellular Assist was turned off because the Shortcuts app isn’t installed.")
	}

	private func _handleShortcutCancel(phase: String) {
		if phase == Command.probe.rawValue {
			_cancelHelperSetup()
			_log("Cellular Assist setup was cancelled.")
			return
		}
		operationID = nil
		_handleShortcutFailure("The Cellular Assist shortcut was cancelled.", phase: phase)
	}

	private func _handleHelperProbeFailure(_ message: String, purpose: HelperProbePurpose) {
		operationID = nil

		switch purpose {
		case .initial:
			_installHelper()
		case .postInstall:
			_finishHelperSetupFailure(message)
		}
	}

	private func _cancelHelperSetup() {
		operationID = nil
		helperSetupPhase = .idle
		isEnabled = false
		UserDefaults.standard.set(false, forKey: Self.enabledKey)
		state = .idle
	}

	private func _finishHelperSetupFailure(_ message: String) {
		retryTask?.cancel()
		retryTask = nil
		operationID = nil
		helperSetupPhase = .idle
		isEnabled = false
		UserDefaults.standard.set(false, forKey: Self.enabledKey)
		state = .failed(message)
		_showFailure(message)
	}

	private func _handleShortcutFailure(_ message: String, phase: String? = nil) {
		guard _shortcutsAvailable() else {
			_disableForMissingShortcuts()
			return
		}
		retryTask?.cancel()
		retryTask = nil
		operationID = nil

		if phase == Command.probe.rawValue || helperSetupPhase != .idle {
			helperSetupPhase = .idle
			isEnabled = false
			UserDefaults.standard.set(false, forKey: Self.enabledKey)
			state = .failed(message)
			_showFailure(message)
			return
		}

		if UserDefaults.standard.bool(forKey: Self.restoreKey) {
			automaticRecoveryEpisode = .consumed
			if !didAttemptRestore {
				_restoreMobileDataOnce()
				return
			}
			state = .failed("Mobile Data may still be off. Turn it back on in Control Center or Settings.")
			_showFailure("Mobile Data may still be off. Turn it back on in Control Center or Settings.")
		} else {
			state = .failed(message)
			_showFailure(message)
		}
	}

	private func _restoreMobileDataOnce(force: Bool = false) {
		guard force || !didAttemptRestore else { return }
		didAttemptRestore = true
		state = .restoringData
		_startShortcut(.on)
	}

	private func _showFailure(_ message: String) {
		UIAlertController.showAlertWithOk(title: "Cellular Assist", message: message)
	}

	private func _log(_ message: String, level: DebugLogItem.Level = .info) {
		DebugLogManager.shared.log(message, category: "Cellular Assist", level: level)
	}
}
