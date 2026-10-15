import SwiftUI
import UIKit

/// Only attaches the SwiftUI search surface to the navigation bar's fixed bounds.
/// Native toolbar items remain responsible for back, title menus, and actions.
struct SearchHeaderOverlay: UIViewRepresentable {
	@Binding var text: String
	var focus: Binding<Bool>
	let title: String
	@ObservedObject var transition: SearchToolbarTransition
	let sourceFrame: CGRect
	let searchInTitle: Bool
	var titleIsLeading = false
	let isScreenActive: Bool
	@Environment(\.layoutDirection) private var layoutDirection

	func makeUIView(context: Context) -> SearchOverlayAttachmentView {
		SearchOverlayAttachmentView()
	}

	func updateUIView(_ view: SearchOverlayAttachmentView, context: Context) {
		view.surface = SearchOverlaySurface(text: $text, focus: focus, title: title,
			transition: transition, layout: view.layout, sourceFrame: sourceFrame,
			searchInTitle: searchInTitle, titleIsLeading: titleIsLeading,
			rightToLeft: layoutDirection == .rightToLeft)
		view.isScreenActive = isScreenActive
		view.acceptsSearchTouches = isScreenActive && transition.expanded
		view.attachIfNeeded()
	}

	static func dismantleUIView(_ view: SearchOverlayAttachmentView, coordinator: ()) {
		view.detach()
	}
}

@MainActor
final class SearchOverlayLayout: ObservableObject {
	@Published var barFrame: CGRect = .zero
}

struct SearchOverlaySurface: View {
	@Binding var text: String
	var focus: Binding<Bool>
	let title: String
	@ObservedObject var transition: SearchToolbarTransition
	@ObservedObject var layout: SearchOverlayLayout
	let sourceFrame: CGRect
	let searchInTitle: Bool
	var titleIsLeading = false
	let rightToLeft: Bool

	var body: some View {
		GeometryReader { geometry in
			let width = max(44, min(600, geometry.size.width - 84))
			let final = CGRect(x: rightToLeft ? geometry.size.width - 16 - width : 16,
				y: (geometry.size.height - 40) / 2, width: width, height: 40)
			let fallbackX = searchInTitle
				? (titleIsLeading ? (rightToLeft ? geometry.size.width - 38 : 38) : geometry.size.width / 2)
				: (rightToLeft ? 38 : geometry.size.width - 38)
			let source = sourceFrame.isEmpty
				? CGPoint(x: fallbackX,
					y: geometry.size.height / 2)
				: CGPoint(x: sourceFrame.midX - layout.barFrame.minX,
					y: sourceFrame.midY - layout.barFrame.minY)
			HStack(spacing: 8) {
				Image(systemName: "magnifyingglass")
					.font(.system(size: 16)).foregroundStyle(.secondary)
				KeyboardSearchField(text: $text, focus: focus,
					prompt: .localized("Search %@", arguments: title), transition: transition)
					.tint(.primary)
			}
			.padding(.horizontal, 12)
			.frame(width: transition.expanded ? final.width : 44,
				height: transition.expanded ? final.height : 44)
			.clipped()
			.glassEffect(.regular.interactive(), in: .capsule)
			.position(CGPoint(x: transition.expanded ? final.midX : source.x, y: source.y))
			.opacity(transition.expanded ? 1 : 0)
			.allowsHitTesting(transition.expanded)
			.accessibilityHidden(!transition.expanded)
			.animation(transition.animation, value: transition.expanded)
		}
	}
}

@MainActor
final class SearchOverlayAttachmentView: UIView {
	let layout = SearchOverlayLayout()
	private var host: UIView?
	private weak var bar: UINavigationBar?
	private let touchContainer = SearchOverlayTouchView()
	// Visibility belongs to the active route, independently of the retained search session.
	var isScreenActive = true {
		didSet { touchContainer.isHidden = !isScreenActive }
	}
	var acceptsSearchTouches = false {
		didSet { touchContainer.acceptsSearchTouches = acceptsSearchTouches }
	}
	var surface: SearchOverlaySurface? {
		didSet {
			guard let surface else { return }
			let configuration = UIHostingConfiguration { surface }
				.margins(.all, 0)
				.minSize(width: 0, height: 0)
			if let content = host as? UIContentView { content.configuration = configuration }
			else {
				let view = configuration.makeContentView()
				view.backgroundColor = .clear
				view.isOpaque = false
				host = view
			}
		}
	}

	override func didMoveToWindow() {
		super.didMoveToWindow()
		if window == nil { detach() }
		else { attachIfNeeded() }
	}

	override func layoutSubviews() {
		super.layoutSubviews()
		attachIfNeeded()
		updateBarFrame()
	}

	func attachIfNeeded() {
		guard window != nil, let host else { return }
		var responder: UIResponder? = self
		var owner: UIViewController?
		while let current = responder {
			if let controller = current as? UIViewController,
				controller.navigationController != nil {
				owner = controller
				break
			}
			responder = current.next
		}
		guard let owner, let target = owner.navigationController?.navigationBar else { return }
		if bar !== target || touchContainer.superview == nil {
			detach()
			bar = target
			touchContainer.frame = target.bounds
			touchContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
			host.frame = touchContainer.bounds
			host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
			touchContainer.addSubview(host)
			target.addSubview(touchContainer)
		}
		updateBarFrame()
	}

	private func updateBarFrame() {
		guard let bar, let window else { return }
		let frame = bar.convert(bar.bounds, to: window)
		guard frame != layout.barFrame else { return }
		DispatchQueue.main.async { [weak self] in
			guard let self, self.bar === bar, self.window != nil,
				self.layout.barFrame != frame else { return }
			self.layout.barFrame = frame
		}
	}

	func detach() {
		touchContainer.removeFromSuperview()
		bar = nil
	}
}

private final class SearchOverlayTouchView: UIView {
	var acceptsSearchTouches = false
	override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
		guard acceptsSearchTouches else { return false }
		let width = max(44, min(600, bounds.width - 84))
		let rightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
		let field = CGRect(x: rightToLeft ? bounds.width - 16 - width : 16,
			y: 0, width: width, height: bounds.height)
		return field.contains(point)
	}
}
