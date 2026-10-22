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
	private var waiters: [CheckedContinuation<Void, Never>] = []

	init(maximumConcurrentRenders: Int) {
		availablePermits = maximumConcurrentRenders
	}

	func acquire() async {
		if availablePermits > 0 {
			availablePermits -= 1
			return
		}

		await withCheckedContinuation { waiters.append($0) }
	}

	func release() {
		if let waiter = waiters.first {
			waiters.removeFirst()
			waiter.resume()
		} else {
			availablePermits += 1
		}
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
	private var task: Task<Void, Never>?
	private var generation = UUID()

	func load(bundleURL: URL, appearance: FRIconAppearance, tint: String, isTinted: Bool, dynamic: Bool, displayScale: CGFloat = 1) {
		task?.cancel()
		task = nil
		generation = UUID()
		let generation = self.generation
		if let cached = FRIconCache.shared.image(for: bundleURL, appearance: appearance, tint: tint, isTinted: isTinted, dynamic: dynamic, displayScale: displayScale) {
			self.image = cached
			return
		}

		task = Task.detached(priority: .userInitiated) { [weak self] in
			await FRIconRenderGate.shared.acquire()
			guard !Task.isCancelled else {
				await FRIconRenderGate.shared.release()
				return
			}

			let generated = iconTest(bundleURL, displayScale, appearance == .dark ? 2 : 1)
			await FRIconRenderGate.shared.release()
			guard !Task.isCancelled, let generated else { return }

			await MainActor.run { [weak self] in
				guard !Task.isCancelled, self?.generation == generation else { return }
				FRIconCache.shared.insert(generated, for: bundleURL, appearance: appearance, tint: tint, isTinted: isTinted, dynamic: dynamic, displayScale: displayScale)
				self?.image = generated
			}
		}
	}

	func cancel() {
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

	@Environment(\.displayScale) private var displayScale
	@Environment(\.colorScheme) private var colorScheme
	@StateObject private var loader = FRAppIconLoader()
	
	@AppStorage("Aether.userTintColor") private var selectedColorHex: String = "#848ef9"
	@AppStorage("Aether.shouldTintIcons") private var shouldTintIcons: Bool = false
	@AppStorage("Aether.shouldChangeIconsBasedOffStyle") private var shouldChangeIconsBasedOffStyle: Bool = false
	
	init(app: AppInfoPresentable? = nil, size: CGFloat = 87, remoteIconURL: URL? = nil, usesDefaultApp: Bool = true) {
		self.app = app
		self.size = size
		self.remoteIconURL = remoteIconURL
		self.usesDefaultApp = usesDefaultApp
	}

	private var appearance: FRIconAppearance {
		colorScheme == .dark ? .dark : .light
	}

	var body: some View {
		Group {
			if let image = loader.image {
				Image(uiImage: image)
					.appIconStyle(size: size)
			} else if let remoteIconURL {
				LazyImage(url: remoteIconURL) { state in
					if let image = state.image { image.appIconStyle(size: size) }
					else { skeleton }
				}.processors([.resize(width: size * displayScale)])
			} else {
				skeleton
			}
		}
		.transaction { $0.animation = nil }
		.task(id: "\(app?.uuid ?? "")|\(app?.isSigned ?? false)|\(appearance.rawValue)\(selectedColorHex)\(shouldTintIcons)\(shouldChangeIconsBasedOffStyle)\(displayScale)") {
			_load()
		}
		.onDisappear {
			loader.cancel()
		}
	}
	
	private var skeleton: some View {
		RoundedRectangle(cornerRadius: size * 0.2677, style: .continuous)
			.fill(Color(uiColor: .tertiarySystemFill))
			.frame(width: size, height: size)
			.accessibilityHidden(true)
	}

	private func _load() {
		let bundleURL: URL

		if let app {
			guard let url = Storage.shared.getAppDirectory(for: app) else { return }
			bundleURL = url
		} else {
			guard usesDefaultApp else { return }
			bundleURL = Bundle.main.bundleURL
		}

		loader.load(
			bundleURL: bundleURL,
			appearance: appearance,
			tint: selectedColorHex,
			isTinted: shouldTintIcons,
			dynamic: shouldChangeIconsBasedOffStyle,
			displayScale: displayScale
		)
	}

}
