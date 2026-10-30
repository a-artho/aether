//
//  OnDevicePairingManager.swift
//  Aether
//
//  Created by Aether.
//

import Foundation
import IDeviceSwift
import UIKit

private struct OnDevicePairingFailure: Error, Sendable {
	let message: String
}

@MainActor
final class OnDevicePairingManager: ObservableObject {
	static let shared = OnDevicePairingManager()

	enum State: Equatable {
		case idle
		case waitingForSettings
		case pairingWithoutCode
		case awaitingCode(String)
		case cancelling
		case completed
		case failed(String)
	}

	@Published private(set) var state: State = .idle

	nonisolated static var isSupported: Bool {
		if #available(iOS 27.0, *) {
			return true
		}
		return ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
	}

	var isActive: Bool {
		switch state {
		case .waitingForSettings, .pairingWithoutCode, .awaitingCode, .cancelling:
			return true
		case .idle, .completed, .failed:
			return false
		}
	}

	private var session: OnDevicePairingSession?
	private var sessionIdentifier: UUID?
	private var completionTask: Task<Void, Never>?
	private var timeoutTask: Task<Void, Never>?
	private var backgroundTaskIdentifier: UIBackgroundTaskIdentifier = .invalid
	private var cancellationFailure: String?
	private var hasContinuedProcessingTask = false

	private init() {}

	func begin() {
		guard Self.isSupported else {
			let message: String = .localized("On-device pairing is only supported on iOS 27 and onwards.")
			state = .failed(message)
			_log(message, level: .warning)
			return
		}
		guard session == nil else { return }
		guard AppMaintenanceGuard.deviceOperationBlockReason == nil else {
			let message = AppMaintenanceGuard.deviceOperationBlockReason ?? String.localized("Work in Progress")
			state = .failed(message)
			_log(message, level: .notice)
			return
		}

		let session = OnDevicePairingSession()
		let identifier = UUID()
		self.session = session
		sessionIdentifier = identifier
		cancellationFailure = nil
		state = .waitingForSettings
		_log("On-device pairing started. Waiting for Settings.", level: .notice)
		#if !targetEnvironment(macCatalyst)
		// Settings takes the foreground during Remote Pairing. Keep Aether's
		// network listener runnable until the code exchange has finished.
		BackgroundAudioManager.shared.start("pairing")
		#endif
		_startContinuedProcessingTask(for: identifier)
		_startTimeout(for: identifier)

		let receiveCode: @Sendable (String) -> Void = { [weak self] code in
			Task { @MainActor [weak self] in
				self?._receive(code: code, for: identifier)
			}
		}
		let nativeTask = Task.detached(priority: .userInitiated) { [session, receiveCode] () -> Result<Data, OnDevicePairingFailure> in
			do {
				let record = try session.run(displayName: "Aether", onCode: receiveCode)
				return .success(record)
			} catch {
				return .failure(OnDevicePairingFailure(message: error.localizedDescription))
			}
		}

		completionTask = Task { [weak self] in
			let result = await nativeTask.value
			guard let self else { return }
			self._finish(result, for: identifier)
		}
	}

	func cancel() {
		_cancel(for: sessionIdentifier, failure: nil)
	}

	/// Request a short protected background window immediately before opening
	/// Settings. Starting it here rather than when pairing begins preserves the
	/// available time for the actual passcode and PIN exchange.
	func prepareForSettings() {
		guard let identifier = sessionIdentifier, isActive else { return }
		_log("Preparing protected background time for pairing.")
		#if !targetEnvironment(macCatalyst)
		if hasContinuedProcessingTask {
			BackgroundTaskManager.shared.markPairingSettingsOpened(for: identifier)
			return
		}
		#endif
		_beginBackgroundGracePeriod(for: identifier)
	}

	func reset() {
		guard !isActive else { return }
		state = .idle
	}

	private func _receive(code: String, for identifier: UUID) {
		guard sessionIdentifier == identifier, session != nil else { return }
		if code == "000000" {
			state = .pairingWithoutCode
			_log("Pairing continued without a code.", level: .notice)
			#if !targetEnvironment(macCatalyst)
			if hasContinuedProcessingTask {
				BackgroundTaskManager.shared.showPairingProgress(
					.localized("Finishing code-free pairing"),
					for: identifier
				)
			}
			#endif
			return
		}
		UIPasteboard.general.string = code
		state = .awaitingCode(code)
		_log("Pairing code received and displayed.", level: .notice)
		#if !targetEnvironment(macCatalyst)
		if hasContinuedProcessingTask {
			BackgroundTaskManager.shared.showPairingCode(code, for: identifier)
		}
		#endif
	}

	private func _finish(_ result: Result<Data, OnDevicePairingFailure>, for identifier: UUID) {
		guard sessionIdentifier == identifier else { return }

		defer {
			session = nil
			sessionIdentifier = nil
			completionTask = nil
			timeoutTask?.cancel()
			timeoutTask = nil
			_endBackgroundGracePeriod()
			_stopContinuedProcessingTask(for: identifier, success: _didCompleteSuccessfully(result))
			#if !targetEnvironment(macCatalyst)
			BackgroundAudioManager.shared.stop("pairing")
			#endif
			if UIApplication.shared.applicationState == .background {
				DeviceConnectionManager.shared.handleAppBackground()
			}
		}

		switch result {
		case .success(let record):
			do {
				try _store(record)
				HeartbeatManager.useOnDevicePairingFile()
				DeviceConnectionManager.shared.refreshAfterPairingRecordChange()
				state = .completed
				_log("Pairing completed and the pairing record was saved.", level: .notice)
			} catch {
				state = .failed(error.localizedDescription)
				_log("Could not save the pairing record: \(error.localizedDescription)", level: .error)
			}
		case .failure(let failure):
			if let cancellationFailure {
				state = .failed(cancellationFailure)
				_log("Pairing stopped: \(cancellationFailure)", level: .warning)
			} else if case .cancelling = state {
				state = .idle
				_log("Pairing cancelled.")
			} else {
				state = .failed(failure.message)
				_log("Pairing failed: \(failure.message)", level: .error)
			}
		}
	}

	private func _cancel(for identifier: UUID?, failure: String?) {
		guard let identifier, identifier == sessionIdentifier, let session else { return }
		if case .cancelling = state {
			return
		}

		cancellationFailure = failure
		state = .cancelling
		_log(failure == nil ? "Cancelling pairing." : "Pairing cancellation requested.", level: .warning)
		session.cancel()
	}

	private func _startTimeout(for identifier: UUID) {
		timeoutTask?.cancel()
		timeoutTask = Task { [weak self] in
			do {
				try await Task.sleep(nanoseconds: 120_000_000_000)
			} catch {
				return
			}
			self?._cancel(
				for: identifier,
				failure: .localized("Pairing timed out. Return to Aether and try again.")
			)
		}
	}

	private func _beginBackgroundGracePeriod(for identifier: UUID) {
		_endBackgroundGracePeriod()
		backgroundTaskIdentifier = UIApplication.shared.beginBackgroundTask(withName: "Aether Remote Pairing") { [weak self] in
			Task { @MainActor in
				self?._cancel(
					for: identifier,
					failure: .localized("Pairing timed out. Return to Aether and try again.")
				)
			}
		}
	}

	private func _endBackgroundGracePeriod() {
		guard backgroundTaskIdentifier != .invalid else { return }
		UIApplication.shared.endBackgroundTask(backgroundTaskIdentifier)
		backgroundTaskIdentifier = .invalid
	}

	private func _startContinuedProcessingTask(for identifier: UUID) {
		#if !targetEnvironment(macCatalyst)
		hasContinuedProcessingTask = BackgroundTaskManager.shared.startPairingTask(
			for: identifier,
			onExpiration: { [weak self] in
				Task { @MainActor [weak self] in
					self?.hasContinuedProcessingTask = false
					self?._cancel(
						for: identifier,
						failure: .localized("Pairing was stopped by iOS. Try again.")
					)
				}
			}
		)
		#endif
	}

	private func _stopContinuedProcessingTask(for identifier: UUID, success: Bool) {
		#if !targetEnvironment(macCatalyst)
		if hasContinuedProcessingTask {
			BackgroundTaskManager.shared.stopPairingTask(for: identifier, success: success)
		}
		#endif
		hasContinuedProcessingTask = false
	}

	private func _didCompleteSuccessfully(_ result: Result<Data, OnDevicePairingFailure>) -> Bool {
		if case .success = result, case .completed = state {
			return true
		}
		return false
	}

	private func _store(_ record: Data) throws {
		let destination = HeartbeatManager.onDevicePairingFileURL()
		try FileManager.default.createDirectory(
			at: destination.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)
		try record.write(
			to: destination,
			options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
		)
	}

	private func _log(_ message: String, level: DebugLogItem.Level = .info) {
		DebugLogManager.shared.log(message, category: "Pairing", level: level)
	}

}
