//
//  BackgroundAudioManager.swift
//  Aether
//
//  Created by Nagata Asami on 12/10/25.
//

#if !targetEnvironment(macCatalyst)

import AVFoundation

class BackgroundAudioManager {
	static let shared = BackgroundAudioManager()
	private let _engine = AVAudioEngine()
	private var _silenceNode: AVAudioSourceNode?
	private var _sessionIsActive = false
	private var _requesters = Set<String>()
	private let _lock = NSLock()

	private init() {}
	
	func start(_ requester: String = "default") {
		_lock.lock()
		defer { _lock.unlock() }
		_requesters.insert(requester)
		guard !_engine.isRunning else { return }
		do {
			let session = AVAudioSession.sharedInstance()
			
			try session.setCategory(.playback, options: [.mixWithOthers])
			try session.setActive(true)
			_sessionIsActive = true
			let silence = AVAudioSourceNode { _, _, _, audioBufferList -> OSStatus in
				let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
				for buffer in ablPointer {
					memset(buffer.mData, 0, Int(buffer.mDataByteSize))
				}
				return noErr
			}
			
			_engine.attach(silence)
			_silenceNode = silence
			_engine.connect(silence, to: _engine.mainMixerNode, format: nil)
			try _engine.start()
		} catch {
			_cleanup()
			print("failed to start engine:", error)
		}
	}
	
	func stop(_ requester: String = "default") {
		_lock.lock()
		defer { _lock.unlock() }
		_requesters.remove(requester)
		guard _requesters.isEmpty else { return }
		_cleanup()
	}

	func stopAll() {
		_lock.lock()
		defer { _lock.unlock() }
		_requesters.removeAll()
		_cleanup()
	}

	// Call with the lock held, including when activation or engine startup fails.
	private func _cleanup() {
		if _engine.isRunning { _engine.stop() }
		if let silence = _silenceNode {
			_engine.disconnectNodeOutput(silence)
			_engine.detach(silence)
			_silenceNode = nil
		}
		if _sessionIsActive {
			do {
				try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
				_sessionIsActive = false
			} catch {
				// Retain ownership so a later stop can retry deactivation.
				print("failed to deactivate audio session:", error)
			}
		}
	}
}

#endif
