//
//  FRAppIconView.swift
//  Aether
//
//  Created by samara on 18.04.2025.
//

import SwiftUI
import NukeUI

enum FRIconAppearance: Int {
	case light = 0
	case dark = 1
}

private actor FRIconRenderGate {
	static let shared = FRIconRenderGate(maximumConcurrentRenders: 2)

    private var availablePermits: Int
    private var waiters: [(UUID, CheckedContinuation<Bool, Never>)] = []
    init(maximumConcurrentRenders: Int) { availablePermits = maximumConcurrentRenders }
    func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        if availablePermits > 0 { availablePermits -= 1; return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false) }
                else { waiters.append((id, continuation)) }
            }
        } onCancel: { Task { await self.cancelWaiter(id) } }
    }
    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(returning: false)
    }
    func release() {
        if !waiters.isEmpty { waiters.removeFirst().1.resume(returning: true) }
        else { availablePermits += 1 }
    }
}

/// Share identical renders; the permit covers actual work rather than each view.
private actor FRIconRequests {
    static let shared = FRIconRequests()
    private struct Flight {
        let id: UUID
        let task: Task<UIImage?, Never>
        var consumers: Set<UUID>
    }
    private var tasks: [String: Flight] = [:]
    func image(url: URL, appearance: FRIconAppearance, tint: String, isTinted: Bool, dynamic: Bool, scale: CGFloat) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        let key = "\(url.path)|\(appearance.rawValue)|\(tint)|\(isTinted)|\(dynamic)|\(scale)"
        let consumer = UUID()
        let flight: Flight
        if var existing = tasks[key] {
            existing.consumers.insert(consumer)
            tasks[key] = existing
            flight = existing
        } else {
            let task = Task.detached(priority: .userInitiated) {
                guard await FRIconRenderGate.shared.acquire() else { return nil as UIImage? }
                guard !Task.isCancelled else { await FRIconRenderGate.shared.release(); return nil as UIImage? }
                let image = iconTest(url, scale, appearance == .dark ? 2 : 1)
                await FRIconRenderGate.shared.release()
                guard !Task.isCancelled else { return nil }
                if let image {
                    FRIconCache.shared.insert(image, for: url, appearance: appearance, tint: tint,
                        isTinted: isTinted, dynamic: dynamic, displayScale: scale)
                }
                return image
            }
            flight = Flight(id: UUID(), task: task, consumers: [consumer])
            tasks[key] = flight
        }
        let result = await withTaskCancellationHandler { await flight.task.value } onCancel: {
            Task { await self.release(key: key, flightID: flight.id, consumer: consumer) }
        }
        release(key: key, flightID: flight.id, consumer: consumer)
        return Task.isCancelled ? nil : result
    }
    private func release(key: String, flightID: UUID, consumer: UUID) {
        guard var flight = tasks[key], flight.id == flightID else { return }
        flight.consumers.remove(consumer)
        if flight.consumers.isEmpty { tasks[key] = nil; flight.task.cancel() }
        else { tasks[key] = flight }
    }
}

// NSCache serializes access; this owner has no other mutable state.
final class FRIconCache: NSObject, @unchecked Sendable {
	static let shared = FRIconCache()
	private let cache = NSCache<NSString, UIImage>()

	private override init() {
		super.init()
		cache.countLimit = 128
		cache.totalCostLimit = 32 * 1024 * 1024
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(invalidateAll),
			name: UIApplication.didReceiveMemoryWarningNotification,
			object: nil
		)
	}

	deinit {
		NotificationCenter.default.removeObserver(self)
	}

	private func key(url: URL, appearance: FRIconAppearance, tint: String, isTinted: Bool, dynamic: Bool, displayScale: CGFloat) -> NSString {
		"\(url.path)#\(appearance.rawValue)#\(tint)#\(isTinted)#\(dynamic)#\(displayScale)" as NSString
	}

	func image(for url: URL, appearance: FRIconAppearance, tint: String, isTinted: Bool, dynamic: Bool, displayScale: CGFloat = 1) -> UIImage? {
		cache.object(forKey: key(url: url, appearance: appearance, tint: tint, isTinted: isTinted, dynamic: dynamic, displayScale: displayScale))
	}

	func insert(_ image: UIImage, for url: URL, appearance: FRIconAppearance, tint: String, isTinted: Bool, dynamic: Bool, displayScale: CGFloat = 1) {
		let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 1
		cache.setObject(
			image,
			forKey: key(url: url, appearance: appearance, tint: tint, isTinted: isTinted, dynamic: dynamic, displayScale: displayScale),
			cost: cost
		)
	}

	@objc func invalidateAll() {
		cache.removeAllObjects()
	}
}

@MainActor
final class FRAppIconLoader: ObservableObject {
	@Published var image: UIImage?
	@Published private(set) var isLoading = false
	private var task: Task<Void, Never>?
	private var generation = UUID()

	func load(bundleURL: URL, appearance: FRIconAppearance, tint: String, isTinted: Bool, dynamic: Bool, displayScale: CGFloat = 1, retainsPreviousImage: Bool = false) {
		task?.cancel()
		task = nil
		generation = UUID()
		let generation = self.generation
		if let cached = FRIconCache.shared.image(for: bundleURL, appearance: appearance, tint: tint, isTinted: isTinted, dynamic: dynamic, displayScale: displayScale) {
			isLoading = false
			self.image = cached
			return
		}

		if !retainsPreviousImage { image = nil }
		isLoading = true
		task = Task.detached(priority: .userInitiated) { [weak self] in
            let generated = await FRIconRequests.shared.image(url: bundleURL, appearance: appearance,
                tint: tint, isTinted: isTinted, dynamic: dynamic, scale: displayScale)
			guard !Task.isCancelled else { return }

			await MainActor.run { [weak self] in
				guard !Task.isCancelled, self?.generation == generation else { return }
				self?.isLoading = false
				if generated != nil || !retainsPreviousImage { self?.image = generated }
			}
		}
	}

	func clear() {
		cancel()
		image = nil
	}

	func cancel() {
		isLoading = false
		generation = UUID()
		task?.cancel()
		task = nil
	}
}

struct FRAppIconView: View {
	private let app: AppInfoPresentable?
	private let size: CGFloat
	private let remoteIconURL: URL?
	private let usesDefaultApp: Bool
	private let retainsPreviousImage: Bool

	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@Environment(\.displayScale) private var displayScale
	@Environment(\.colorScheme) private var colorScheme
	@StateObject private var loader = FRAppIconLoader()
	
	@AppStorage("Aether.userTintColor") private var selectedColorHex: String = "#848ef9"
	@AppStorage("Aether.shouldTintIcons") private var shouldTintIcons: Bool = false
	@AppStorage("Aether.shouldChangeIconsBasedOffStyle") private var shouldChangeIconsBasedOffStyle: Bool = false
	
	init(app: AppInfoPresentable? = nil, size: CGFloat = 87, remoteIconURL: URL? = nil, usesDefaultApp: Bool = true, retainsPreviousImage: Bool = false) {
		self.app = app
		self.size = size
		self.remoteIconURL = remoteIconURL
		self.usesDefaultApp = usesDefaultApp
		self.retainsPreviousImage = retainsPreviousImage
	}

	private var appearance: FRIconAppearance {
		colorScheme == .dark ? .dark : .light
	}

	var body: some View {
		ZStack {
			if let image = loader.image {
				Image(uiImage: image)
					.appIconStyle(size: size)
					.transition(.opacity)
			} else if let remoteIconURL {
				LazyImage(url: remoteIconURL) { state in
					ZStack {
						if let image = state.image {
							image.appIconStyle(size: size).transition(.opacity)
						} else {
							AppIconSkeleton(size: size, isLoading: state.isLoading).transition(.opacity)
						}
					}
					.animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: state.image != nil)
				}.processors([.resize(width: size * displayScale)])
			} else {
				skeleton
			}
		}
		.frame(width: size, height: size)
		// Fade the initial placeholder handoff, not each new render of an
		// already-visible icon when signing changes the artifact's identity.
		.animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: loader.image != nil)
		.task(id: "\(app?.uuid ?? "")|\(app?.isSigned ?? false)|\(appearance.rawValue)\(selectedColorHex)\(shouldTintIcons)\(shouldChangeIconsBasedOffStyle)\(displayScale)") {
			await _load()
		}
		.onDisappear {
			loader.cancel()
		}
	}
	
	private var skeleton: some View {
		AppIconSkeleton(size: size, isLoading: loader.isLoading)
	}

	private func _load() async {
		let bundleURL: URL

		if let app {
			guard let directory = Storage.shared.getUuidDirectory(for: app) else { loader.clear(); return }
			let found = await Task.detached(priority: .userInitiated) { FileManager.default.getPath(in: directory, for: "app") }.value
			guard !Task.isCancelled else { return }
			guard let url = found else { loader.clear(); return }
			bundleURL = url
		} else {
			guard usesDefaultApp else { loader.clear(); return }
			bundleURL = Bundle.main.bundleURL
		}

		loader.load(
			bundleURL: bundleURL,
			appearance: appearance,
			tint: selectedColorHex,
			isTinted: shouldTintIcons,
			dynamic: shouldChangeIconsBasedOffStyle,
			displayScale: displayScale,
			retainsPreviousImage: retainsPreviousImage
		)
	}

}
