import Foundation
import UIKit
import IDevice
import CryptoKit
import Darwin
import Network

/// Opt-in diagnostics only. No timer, per-chunk log, or awaited log delivery.
/// Worker-owned counters are separate from the notification-driven lifecycle state.
final class InstallationTransferDiagnostics: @unchecked Sendable {
	private let id: String
	private let emit: @Sendable (String) -> Void
	private let started: TimeInterval
	private let clock: @Sendable () -> TimeInterval
	private var phase = "setup"
	private var phaseStarted: TimeInterval
	private var totalBytes: Int64 = 0
	private var written: Int64 = 0
	private var chunks = 0
	private var readSeconds: TimeInterval = 0
	private var writeSeconds: TimeInterval = 0
	private var progressSeconds: TimeInterval = 0
	private var maxWrite: TimeInterval = 0
	private var maxProgress: TimeInterval = 0
	private var lastSample: TimeInterval
	private var lastBytes: Int64 = 0
	private var native = AfcWriteDiagnostics()
	private var writeBuckets = [Int](repeating: 0, count: 6)
	private var replyBuckets = [Int](repeating: 0, count: 6)
	private var maxReply: Double = 0
	private var hash = SHA256()
	private var hashSeconds: Double = 0
	private var fingerprintLogged = false
	private var lastCPU: Double = 0
	private var totalCPU: Double = 0
	private var peakResident: UInt64 = 0
	private var lastResourceSample: Double = 0
	private let pathMonitor = NWPathMonitor()
	private var network = "pending"
	private let stateLock = NSLock()
	private var state: String
	private var protectedData: Bool
	private var observers: [NSObjectProtocol] = []

	@MainActor
	init(id: String, clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, emit: @escaping @Sendable (String) -> Void) {
		let time = clock()
		self.started = time
		self.clock = clock
		self.id = id
		self.emit = emit
		self.phaseStarted = time
		self.lastSample = time
		switch UIApplication.shared.applicationState {
		case .active: state = "active"
		case .background: state = "background"
		default: state = "inactive"
		}
		protectedData = UIApplication.shared.isProtectedDataAvailable
		observe(UIApplication.didEnterBackgroundNotification, state: "background")
		observe(UIApplication.willEnterForegroundNotification, state: "inactive")
		observe(UIApplication.didBecomeActiveNotification, state: "active")
		observe(UIApplication.willResignActiveNotification, state: "inactive")
		observe(UIApplication.protectedDataWillBecomeUnavailableNotification, protectedData: false)
		observe(UIApplication.protectedDataDidBecomeAvailableNotification, protectedData: true)
		observe(ProcessInfo.thermalStateDidChangeNotification)
		observe(Notification.Name.NSProcessInfoPowerStateDidChange)
		pathMonitor.pathUpdateHandler = { [weak self] path in
			guard let self else { return }
			let types: [NWInterface.InterfaceType] = [.wifi, .cellular, .wiredEthernet, .loopback, .other]
			let interfaces = types.filter { path.usesInterfaceType($0) }.map { String(describing: $0) }.joined(separator: ",")
			self.stateLock.lock()
			self.network = "interfaces=\(interfaces) satisfied=\(path.status == .satisfied) expensive=\(path.isExpensive) constrained=\(path.isConstrained)"
			self.stateLock.unlock()
			self.log("network-path \(self.networkSnapshot)")
		}
		pathMonitor.start(queue: DispatchQueue(label: "Aether.install.diagnostics.network", qos: .utility))
		lastCPU = cpuSeconds()
		lastResourceSample = time
		log("begin os=\(ProcessInfo.processInfo.operatingSystemVersionString) thermal=\(ProcessInfo.processInfo.thermalState.rawValue) lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled)")
	}

	deinit {
		pathMonitor.cancel()
		for observer in observers { NotificationCenter.default.removeObserver(observer) }
	}

	private func observe(_ name: Notification.Name, state: String? = nil, protectedData: Bool? = nil) {
		observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
			guard let self else { return }
			self.stateLock.lock()
			if let state { self.state = state }
			if let protectedData { self.protectedData = protectedData }
			self.stateLock.unlock()
			self.log("lifecycle event=\(name.rawValue) thermal=\(ProcessInfo.processInfo.thermalState.rawValue) lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled)")
		})
	}

	func transport(isRSD: Bool) { log("transport protocol=\(isRSD ? "rsd" : "legacy") diagnosticSchema=2 nativeWriteLimit=4194304 socketSubdivision=65536") }

	func now() -> TimeInterval { clock() }

	func stage(_ next: String) {
		let time = now()
		log("phase-end phase=\(phase) seconds=\(number(time - phaseStarted))")
		phase = next
		phaseStarted = time
		log("phase-start phase=\(next) priority=\(Task.currentPriority.rawValue)")
	}

	func beginUpload(bytes: Int64, chunkBytes: Int) {
		totalBytes = bytes
		stage("upload")
		lastSample = now()
		log("payload bytes=\(bytes) chunkBytes=\(chunkBytes)")
	}

	func recordPayload(_ data: Data) {
		let start = now()
		hash.update(data: data)
		hashSeconds += now() - start
	}

	func recordNative(_ metrics: AfcWriteDiagnostics) {
		native.queue_seconds += metrics.queue_seconds
		native.worker_seconds += metrics.worker_seconds
		native.return_seconds += metrics.return_seconds
		native.copy_seconds += metrics.copy_seconds
		native.serialize_seconds += metrics.serialize_seconds
		native.socket_write_seconds += metrics.socket_write_seconds
		native.flush_seconds += metrics.flush_seconds
		native.reply_seconds += metrics.reply_seconds
		native.poll_seconds += metrics.poll_seconds
		native.max_poll_seconds = max(native.max_poll_seconds, metrics.max_poll_seconds)
		native.packets += metrics.packets
		native.replies += metrics.replies
		native.socket_bytes += metrics.socket_bytes
		native.write_polls += metrics.write_polls
		native.pending_polls += metrics.pending_polls
		native.flush_polls += metrics.flush_polls
		native.flush_pending_polls += metrics.flush_pending_polls
		maxReply = max(maxReply, metrics.reply_seconds)
		replyBuckets[bucket(metrics.reply_seconds)] += 1
	}

	private func bucket(_ seconds: Double) -> Int {
		[0.01, 0.05, 0.25, 1.0, 3.0].firstIndex(where: { seconds < $0 }) ?? 5
	}

	func recordRead(seconds: TimeInterval) { readSeconds += seconds }

	func recordWrite(bytes: Int, seconds: TimeInterval, succeeded: Bool) {
		chunks += 1
		writeSeconds += seconds
		writeBuckets[bucket(seconds)] += 1
		maxWrite = max(maxWrite, seconds)
		if succeeded { written += Int64(bytes) }
	}

	func recordProgress(seconds: TimeInterval) {
		progressSeconds += seconds
		maxProgress = max(maxProgress, seconds)
		let time = now()
		guard time - lastSample >= 5 else { return }
		let rate = Double(written - lastBytes) / (time - lastSample) / 1_048_576
		log("upload-sample bytes=\(written)/\(totalBytes) intervalSeconds=\(number(time - lastSample)) intervalMiBps=\(number(rate)) priority=\(Task.currentPriority.rawValue) \(counters) \(resources())")
		lastSample = time
		lastBytes = written
	}

	func endUpload() {
		if written == totalBytes, totalBytes > 0, !fingerprintLogged {
			fingerprintLogged = true
			let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
			log("payload-fingerprint sha256=\(digest) hashSeconds=\(number(hashSeconds))")
		}
		let elapsed = now() - phaseStarted
		log("upload-summary bytes=\(written)/\(totalBytes) wallSeconds=\(number(elapsed)) MiBps=\(number(Double(written) / max(elapsed, 0.000001) / 1_048_576)) \(counters) \(resources())")
	}

	func finish(outcome: String) {
		if phase == "upload" { endUpload() }
		log("end outcome=\(outcome) phase=\(phase) phaseSeconds=\(number(now() - phaseStarted)) totalSeconds=\(number(now() - started)) \(counters) \(resources())")
	}

	private var counters: String {
		"chunks=\(chunks) readSeconds=\(number(readSeconds)) nativeWriteSeconds=\(number(writeSeconds)) progressAwaitSeconds=\(number(progressSeconds)) maxWriteSeconds=\(number(maxWrite)) maxProgressAwaitSeconds=\(number(maxProgress)) nativePackets=\(native.packets) validReplies=\(native.replies) wireBytes=\(native.socket_bytes) runtimeQueueSeconds=\(number(native.queue_seconds)) runtimeReturnSeconds=\(number(native.return_seconds)) workerSeconds=\(number(native.worker_seconds)) copySeconds=\(number(native.copy_seconds)) serializeSeconds=\(number(native.serialize_seconds)) socketWriteSeconds=\(number(native.socket_write_seconds)) flushSeconds=\(number(native.flush_seconds)) replySeconds=\(number(native.reply_seconds)) socketPollSeconds=\(number(native.poll_seconds)) maxSocketPollSeconds=\(number(native.max_poll_seconds)) socketWritePolls=\(native.write_polls) socketPendingPolls=\(native.pending_polls) flushPolls=\(native.flush_polls) flushPendingPolls=\(native.flush_pending_polls) maxReplySeconds=\(number(maxReply)) writeBuckets=\(writeBuckets) replyBuckets=\(replyBuckets) hashSeconds=\(number(hashSeconds))"
	}

	private var networkSnapshot: String {
		stateLock.lock()
		defer { stateLock.unlock() }
		return network
	}

	private func cpuSeconds() -> Double {
		var usage = rusage()
		guard getrusage(RUSAGE_SELF, &usage) == 0 else { return lastCPU }
		return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
			+ Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
	}

	private func resources() -> String {
		let time = now(), cpu = cpuSeconds()
		let cpuDelta = max(0, cpu - lastCPU), interval = max(0.000001, time - lastResourceSample)
		lastCPU = cpu
		totalCPU += cpuDelta
		lastResourceSample = time
		var info = mach_task_basic_info()
		var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
		let result = withUnsafeMutablePointer(to: &info) { pointer in
			pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
				task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
			}
		}
		if result == KERN_SUCCESS { peakResident = max(peakResident, UInt64(info.resident_size)) }
		return "totalProcessCPUSeconds=\(number(totalCPU)) peakSampledResidentBytes=\(peakResident) processCPUSeconds=\(number(cpuDelta)) processCPUPercent=\(number(100 * cpuDelta / interval)) resourceIntervalSeconds=\(number(interval)) residentBytes=\(result == KERN_SUCCESS ? String(info.resident_size) : "unavailable") thermal=\(ProcessInfo.processInfo.thermalState.rawValue) lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled) \(networkSnapshot)"
	}

	private func number(_ value: Double) -> String { String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value) }

	private func log(_ message: String) {
		stateLock.lock()
		let lifecycle = "state=\(state) protectedData=\(protectedData)"
		stateLock.unlock()
		emit("transfer[\(id)] elapsed=\(number(now() - started)) \(lifecycle) \(message)")
	}
}
