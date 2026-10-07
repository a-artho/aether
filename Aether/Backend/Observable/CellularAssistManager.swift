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
	private var activeCommand: Command?
	private var helperSetupPhase: HelperSetupPhase = .idle
	private var documentController: UIDocumentInteractionController?
	private var retryTask: Task<Void, Never>?
	private var callbackRecoveryTask: Task<Void, Never>?
	private var didAttemptRestore = false
	private var didPresentTerminalPrompt = false
	private var pendingTransportFailureMessage: String?
	private var automaticRecoveryEpisode: AutomaticRecoveryEpisode = .armed

	private override init() {
		isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
		super.init()
	}

	public func requestEnabled(_ enabled: Bool) {
		guard enabled else {
			_cancelHelperSetup()
			return
		}
		guard !isBusy else { return }
		didPresentTerminalPrompt = false
		pendingTransportFailureMessage = nil
		_clearActiveOperation()
		helperSetupPhase = .idle
		isEnabled = false
		UserDefaults.standard.set(false, forKey: Self.enabledKey)
		guard _shortcutsAvailable() else {
			_disableForMissingShortcuts()
			return
		}
		automaticRecoveryEpisode = .armed
		helperSetupPhase = .probing(.initial)
		state = .checkingSetup
		_startShortcut(.probe)
	}

	/// Begins one automatic cellular recovery cycle after the in-app tunnel is
	/// running and Aether knows the active physical route is cellular-only.
	@discardableResult
	public func beginBootstrapIfPossible(cellularOnly: Bool, tunnelIsRunning: Bool) -> Bool {
		guard isEnabled, !isBusy, cellularOnly, tunnelIsRunning,
			automaticRecoveryEpisode == .armed else { return false }
		didPresentTerminalPrompt = false
		guard _shortcutsAvailable() else {
			_disableForMissingShortcuts()
			return false
		}

		automaticRecoveryEpisode = .active
		didAttemptRestore = false
		pendingTransportFailureMessage = nil
		state = .waitingForDataOff
		// Record the restore debt before launching Shortcuts. If Aether or
		// Shortcuts is terminated after Mobile Data changes but before the
		// callback arrives, the next foreground can still restore it.
		UserDefaults.standard.set(true, forKey: Self.restoreKey)
		_startShortcut(.off)
		return true
	}

	public func handleCallback(_ url: URL) {
		guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
		var values: [String: String] = [:]
		for item in components.queryItems ?? [] {
			guard let value = item.value else { continue }
			guard values[item.name] == nil else {
				_log("Ignored an ambiguous shortcut callback with duplicate parameters.", level: .warning)
				return
			}
			values[item.name] = value
		}
		guard let rawID = values["operation"], let callbackID = UUID(uuidString: rawID), callbackID == operationID,
			let phase = values["phase"], let command = Command(rawValue: phase), command == activeCommand,
			let status = values["status"] else {
			_log("Ignored a stale or malformed shortcut callback.", level: .warning)
			return
		}

		if status == "cancel" {
			_handleShortcutCancel(command: command)
			return
		}

		if status != "success" {
			let message = values["errorMessage"] ?? "The Cellular Assist shortcut did not finish."
			if command == .probe,
				case let .probing(purpose) = helperSetupPhase {
				_handleHelperProbeFailure(message, purpose: purpose)
				return
			}
			_handleRuntimeFailure(message, command: command)
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
			_clearActiveOperation()
			state = .idle
			_log("Cellular Assist helper verified.")
		case Command.off.rawValue:
			guard values["result"] == "\(Self.helperVersion)_OFF" else {
				_handleRuntimeFailure("Aether Cellular failed or isn’t configured.", command: .off)
				return
			}
			UserDefaults.standard.set(true, forKey: Self.restoreKey)
			_clearActiveOperation()
			state = .establishingTransport
			_retryTransportWhileDataIsOff()
		case Command.on.rawValue:
			guard values["result"] == "\(Self.helperVersion)_ON" else {
				_handleRuntimeFailure(
					"Mobile Data may still be off. Check it in Settings.",
					command: .on,
					preservingRestoreDebt: true
				)
				return
			}
			UserDefaults.standard.set(false, forKey: Self.restoreKey)
			_clearActiveOperation()
			automaticRecoveryEpisode = .consumed
			if let pendingTransportFailureMessage {
				self.pendingTransportFailureMessage = nil
				_finishRuntimeFailure(pendingTransportFailureMessage)
			} else {
				state = .idle
				_log("Cellular Assist restored Mobile Data after the device tunnel connected.")
			}
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
		// URL callbacks can arrive just after activation. Give the normal callback
		// a chance to finish, then recover a lost callback in this same process.
		if UserDefaults.standard.bool(forKey: Self.restoreKey),
			(state == .waitingForDataOff || state == .restoringData), let pending = operationID {
			callbackRecoveryTask?.cancel()
			callbackRecoveryTask = Task { [weak self] in
				do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
				guard let self, self.operationID == pending,
					UserDefaults.standard.bool(forKey: Self.restoreKey) else { return }
				self._log("Shortcut callback was lost; restoring Mobile Data on return.", level: .warning)
				self._clearActiveOperation()
				self._restoreMobileDataOnce(force: true)
			}
			return
		}
		guard isEnabled, UserDefaults.standard.bool(forKey: Self.restoreKey), !isBusy, !didAttemptRestore else { return }
		guard _shortcutsAvailable() else {
			_disableForMissingShortcuts()
			return
		}
		_restoreMobileDataOnce()
	}

	public func cancelAndRestoreIfNeeded() {
		retryTask?.cancel()
		retryTask = nil
		_clearActiveOperation()
		guard isEnabled, UserDefaults.standard.bool(forKey: Self.restoreKey) else {
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
			self.pendingTransportFailureMessage = "The device tunnel could not be established."
			self._restoreMobileDataOnce()
		}
	}

	private func _startShortcut(_ command: Command) {
		guard _shortcutsAvailable() else {
			if command == .off {
				UserDefaults.standard.set(false, forKey: Self.restoreKey)
			}
			_disableForMissingShortcuts()
			return
		}
		let id = UUID()
		operationID = id
		activeCommand = command
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
			guard let self, !opened, self.operationID == id, self.activeCommand == command else { return }
			if command == .off {
				UserDefaults.standard.set(false, forKey: Self.restoreKey)
			}
			self._disableForMissingShortcuts()
		}
	}

	private func _installHelper() {
		_clearActiveOperation()
		helperSetupPhase = .presentingInstaller
		state = .installingHelper
		guard let url = Bundle.main.url(forResource: Self.helperName, withExtension: "shortcut"),
			let presenter = UIApplication.topViewController() else {
			_finishHelperSetupFailure("The Cellular Assist helper is unavailable.")
			return
		}
		let controller = UIDocumentInteractionController(url: url)
		controller.delegate = self
		documentController = controller
		let presented = controller.presentOpenInMenu(
			from: presenter.view.bounds,
			in: presenter.view,
			animated: true
		)
		guard presented else {
			documentController = nil
			_finishHelperSetupFailure("Aether could not present the Cellular Assist helper.")
			return
		}
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
		URL(string: "shortcuts://").map { UIApplication.shared.canOpenURL($0) } ?? false
	}

	private func _disableForMissingShortcuts() {
		let shouldPreserveRestoreDebt = UserDefaults.standard.bool(forKey: Self.restoreKey)
		let message = shouldPreserveRestoreDebt
			? "Apple Shortcuts isn’t available. Mobile Data may still be off. Check it in Settings."
			: "Apple Shortcuts isn’t available."
		_finishRuntimeFailure(
			message,
			preservingRestoreDebt: shouldPreserveRestoreDebt,
			showShortcutsUnavailablePrompt: true
		)
	}

	private func _handleShortcutCancel(command: Command) {
		switch command {
		case .probe:
			guard case let .probing(purpose) = helperSetupPhase else { return }
			switch purpose {
			case .initial:
				_cancelHelperSetup()
				_log("Cellular Assist setup was cancelled.")
			case .postInstall:
				_finishPostInstallVerificationFailure()
			}
		case .off, .on:
			_handleRuntimeFailure(
				command == .on ? "Mobile Data may still be off. Check it in Settings." : "Aether Cellular failed or isn’t configured.",
				command: command,
				preservingRestoreDebt: command == .on && UserDefaults.standard.bool(forKey: Self.restoreKey)
			)
		}
	}

	private func _handleHelperProbeFailure(_ message: String, purpose: HelperProbePurpose) {
		_clearActiveOperation()

		switch purpose {
		case .initial:
			_installHelper()
		case .postInstall:
			_finishPostInstallVerificationFailure()
		}
	}

	private func _cancelHelperSetup() {
		retryTask?.cancel()
		retryTask = nil
		pendingTransportFailureMessage = nil
		_clearActiveOperation()
		helperSetupPhase = .idle
		didAttemptRestore = false
		automaticRecoveryEpisode = .consumed
		isEnabled = false
		UserDefaults.standard.set(false, forKey: Self.enabledKey)
		state = .idle
	}

	private func _finishHelperSetupFailure(_ message: String) {
		_finishTerminalState(preservingRestoreDebt: false, state: .failed(message))
		_presentTerminalAlert(title: "Cellular Assist", message: message)
	}

	private func _finishPostInstallVerificationFailure() {
		_finishTerminalState(preservingRestoreDebt: false, state: .failed("Shortcut Not Ready"))
		guard !didPresentTerminalPrompt else { return }
		didPresentTerminalPrompt = true
		let retry = UIAlertAction(title: .localized("Try Again"), style: .default) { [weak self] _ in
			self?._retryPostInstallVerification()
		}
		UIAlertController.showAlertWithCancel(
			title: .localized("Shortcut Not Ready"),
			message: .localized("Add Aether Cellular in Shortcuts and choose Always Allow, then try again."),
			actions: [retry]
		)
	}

	private func _retryPostInstallVerification() {
		guard !isBusy else { return }
		didPresentTerminalPrompt = false
		guard _shortcutsAvailable() else {
			_disableForMissingShortcuts()
			return
		}
		helperSetupPhase = .probing(.postInstall)
		state = .checkingSetup
		_startShortcut(.probe)
	}

	private func _handleRuntimeFailure(
		_ message: String,
		command: Command? = nil,
		preservingRestoreDebt: Bool = false
	) {
		let shouldPreserveRestoreDebt = preservingRestoreDebt || (command == .on && UserDefaults.standard.bool(forKey: Self.restoreKey))
		_finishRuntimeFailure(message, preservingRestoreDebt: shouldPreserveRestoreDebt)
	}

	private func _finishRuntimeFailure(
		_ message: String,
		preservingRestoreDebt: Bool = false,
		showShortcutsUnavailablePrompt: Bool = false
	) {
		_finishTerminalState(preservingRestoreDebt: preservingRestoreDebt, state: .failed(message))
		if showShortcutsUnavailablePrompt {
			_presentShortcutsUnavailableAlert(message: message)
		} else {
			_presentTerminalAlert(title: "Cellular Assist Disabled", message: message)
		}
	}

	private func _finishTerminalState(preservingRestoreDebt: Bool, state: State) {
		retryTask?.cancel()
		retryTask = nil
		pendingTransportFailureMessage = nil
		_clearActiveOperation()
		helperSetupPhase = .idle
		didAttemptRestore = false
		automaticRecoveryEpisode = .consumed
		isEnabled = false
		UserDefaults.standard.set(false, forKey: Self.enabledKey)
		if !preservingRestoreDebt {
			UserDefaults.standard.set(false, forKey: Self.restoreKey)
		}
		self.state = state
	}

	private func _clearActiveOperation() {
		callbackRecoveryTask?.cancel()
		callbackRecoveryTask = nil
		operationID = nil
		activeCommand = nil
	}

	private func _restoreMobileDataOnce(force: Bool = false) {
		guard force || !didAttemptRestore else { return }
		didAttemptRestore = true
		state = .restoringData
		_startShortcut(.on)
	}

	private func _presentShortcutsUnavailableAlert(message: String) {
		guard !didPresentTerminalPrompt else { return }
		didPresentTerminalPrompt = true
		let appStore = UIAlertAction(title: .localized("Open App Store"), style: .default) { _ in
			guard let url = URL(string: "itms-apps://apps.apple.com/app/shortcuts/id1462947752") else { return }
			UIApplication.shared.open(url)
		}
		UIAlertController.showAlertWithCancel(
			title: .localized("Cellular Assist Disabled"),
			message: message,
			actions: [appStore]
		)
	}

	private func _presentTerminalAlert(title: String, message: String) {
		guard !didPresentTerminalPrompt else { return }
		didPresentTerminalPrompt = true
		UIAlertController.showAlertWithOk(title: title, message: message)
	}

	private func _log(_ message: String, level: DebugLogItem.Level = .info) {
		DebugLogManager.shared.log(message, category: "Cellular Assist", level: level)
	}
}
