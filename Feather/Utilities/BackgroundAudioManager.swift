//
//  BackgroundAudioManager.swift
//  Feather
//
//  Created by Nagata Asami on 12/10/25.
//

#if !targetEnvironment(macCatalyst)

import AVFoundation

class BackgroundAudioManager {
	static let shared = BackgroundAudioManager()
	private let _engine = AVAudioEngine()
	private var _silenceNode: AVAudioSourceNode?

	private init() {}
	
	func start() {
		guard !_engine.isRunning else { return }
		do {
			let session = AVAudioSession.sharedInstance()
			
			try session.setCategory(.playback, options: [.mixWithOthers])
			try session.setActive(true)
			let silence = AVAudioSourceNode { _, _, _, audioBufferList -> OSStatus in
				let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
				for buffer in ablPointer {
					memset(buffer.mData, 0, Int(buffer.mDataByteSize))
				}
				return noErr
			}
			
			_engine.attach(silence)
			_engine.connect(silence, to: _engine.mainMixerNode, format: nil)
			try _engine.start()
			_silenceNode = silence
		} catch {
			print("failed to start engine:", error)
		}
	}
	
	func stop() {
		_engine.stop()
		if let silence = _silenceNode {
			_engine.disconnectNodeOutput(silence)
			_engine.detach(silence)
			_silenceNode = nil
		}
		try? AVAudioSession.sharedInstance().setActive(
			false,
			options: .notifyOthersOnDeactivation
		)
	}
}

#endif
