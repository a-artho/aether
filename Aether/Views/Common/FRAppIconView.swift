//
//  FRAppIconView.swift
//  Aether
//
//  Created by samara on 18.04.2025.
//

import SwiftUI

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

final class FRIconCache: NSObject {
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

	private func key(url: URL, appearance: FRIconAppearance, tint: String, isTinted: Bool, dynamic: Bool) -> NSString {
		"\(url.path)#\(appearance.rawValue)#\(tint)#\(isTinted)#\(dynamic)" as NSString
	}

	func image(for url: URL, appearance: FRIconAppearance, tint: String, isTinted: Bool, dynamic: Bool) -> UIImage? {
		cache.object(forKey: key(url: url, appearance: appearance, tint: tint, isTinted: isTinted, dynamic: dynamic))
	}

	func insert(_ image: UIImage, for url: URL, appearance: FRIconAppearance, tint: String, isTinted: Bool, dynamic: Bool) {
		let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 1
		cache.setObject(
			image,
			forKey: key(url: url, appearance: appearance, tint: tint, isTinted: isTinted, dynamic: dynamic),
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

	func load(bundleURL: URL, appearance: FRIconAppearance, tint: String, isTinted: Bool, dynamic: Bool) {
		if let cached = FRIconCache.shared.image(for: bundleURL, appearance: appearance, tint: tint, isTinted: isTinted, dynamic: dynamic) {
			self.image = cached
			return
		}

		task?.cancel()
		task = Task.detached(priority: .userInitiated) { [weak self] in
			await FRIconRenderGate.shared.acquire()
			guard !Task.isCancelled else {
				await FRIconRenderGate.shared.release()
				return
			}

			let generated = iconTest(bundleURL)
			await FRIconRenderGate.shared.release()
			guard !Task.isCancelled, let generated else { return }

			await MainActor.run {
				guard !Task.isCancelled else { return }
				FRIconCache.shared.insert(generated, for: bundleURL, appearance: appearance, tint: tint, isTinted: isTinted, dynamic: dynamic)
				self?.image = generated
			}
		}
	}

	func cancel() {
		task?.cancel()
	}
}

struct FRAppIconView: View {
	private let app: AppInfoPresentable?
	private let size: CGFloat

	@Environment(\.colorScheme) private var colorScheme
	@StateObject private var loader = FRAppIconLoader()
	
	@AppStorage("Aether.userTintColor") private var selectedColorHex: String = "#848ef9"
	@AppStorage("Aether.shouldTintIcons") private var shouldTintIcons: Bool = false
	@AppStorage("Aether.shouldChangeIconsBasedOffStyle") private var shouldChangeIconsBasedOffStyle: Bool = false
	
	init(app: AppInfoPresentable? = nil, size: CGFloat = 87) {
		self.app = app
		self.size = size
	}

	private var appearance: FRIconAppearance {
		colorScheme == .dark ? .dark : .light
	}

	var body: some View {
		Group {
			if let image = loader.image {
				Image(uiImage: image)
					.appIconStyle(size: size)
			} else {
				Image("App_Unknown")
					.appIconStyle(size: size)
			}
		}
		.task(id: "\(appearance.rawValue)\(selectedColorHex)\(shouldTintIcons)\(shouldChangeIconsBasedOffStyle)") {
			_load()
		}
		.onDisappear {
			loader.cancel()
		}
	}
	
	private func _load() {
		let bundleURL: URL

		if let app {
			guard let url = Storage.shared.getAppDirectory(for: app) else { return }
			bundleURL = url
		} else {
			bundleURL = Bundle.main.bundleURL
		}

		loader.load(
			bundleURL: bundleURL,
			appearance: appearance,
			tint: selectedColorHex,
			isTinted: shouldTintIcons,
			dynamic: shouldChangeIconsBasedOffStyle
		)
	}

}
