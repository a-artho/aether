import SwiftUI
import UIKit

/// Only attaches the SwiftUI search surface to the navigation bar's fixed bounds.
/// Native toolbar items remain responsible for back, title menus, and actions.
struct SearchHeaderOverlay: UIViewRepresentable {
	@Binding var text: String
	var focus: Binding<Bool>
	let title: String
	@ObservedObject var transition: SearchToolbarTransition
	let sourceAnchor: WindowFrameAnchor?
	let searchInTitle: Bool
	var titleIsLeading = false
	let isScreenActive: Bool
	@Environment(\.layoutDirection) private var layoutDirection

	func makeUIView(context: Context) -> SearchOverlayAttachmentView {
		SearchOverlayAttachmentView()
	}

	func updateUIView(_ view: SearchOverlayAttachmentView, context: Context) {
		view.isScreenActive = isScreenActive
		view.surface = SearchOverlaySurface(text: $text, focus: Binding(get: { isScreenActive && focus.wrappedValue },
			set: { focus.wrappedValue = $0 }), title: title,
			transition: transition, layout: view.layout, sourceAnchor: sourceAnchor,
			searchFieldOwner: view.searchFieldOwner,
			searchInTitle: searchInTitle, titleIsLeading: titleIsLeading,
			rightToLeft: layoutDirection == .rightToLeft,
			isScreenActive: isScreenActive)
		view.acceptsSearchTouches = isScreenActive && transition.expanded
		if isScreenActive { view.attachIfNeeded() }
		else { view.deactivateAndDetach() }
	}

	static func dismantleUIView(_ view: SearchOverlayAttachmentView, coordinator: ()) {
		view.tearDown()
	}
}

struct WindowFrameAnchor: Equatable {
	let frame: CGRect
	let windowID: ObjectIdentifier
}

/// Reports a SwiftUI control's frame in the same UIWindow coordinates used by UIKit.
@MainActor
struct WindowFrameReader: UIViewRepresentable {
	let onChange: (WindowFrameAnchor?) -> Void

	func makeUIView(context: Context) -> WindowFrameReportingView {
		WindowFrameReportingView(onChange: onChange)
	}

	func updateUIView(_ view: WindowFrameReportingView, context: Context) {
		view.onChange = onChange
		view.reportFrame()
	}

	static func dismantleUIView(_ view: WindowFrameReportingView, coordinator: ()) {
		view.invalidate()
	}
}

@MainActor
final class WindowFrameReportingView: UIView {
	var onChange: ((WindowFrameAnchor?) -> Void)?
	private var lastAnchor: WindowFrameAnchor?
	private var generation = 0

	init(onChange: ((WindowFrameAnchor?) -> Void)?) {
		self.onChange = onChange
		super.init(frame: .zero)
		backgroundColor = .clear
		isUserInteractionEnabled = false
		isAccessibilityElement = false
	}

	required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

	override func didMoveToWindow() {
		super.didMoveToWindow()
		generation += 1
		reportFrame()
	}

	override func layoutSubviews() {
		super.layoutSubviews()
		reportFrame()
	}

	func reportFrame() {
		guard let window else {
			publish(nil)
			return
		}
		let frame = convert(bounds, to: window)
		guard frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite,
			frame.height.isFinite, !frame.isNull, !frame.isEmpty else {
			// Invalidate the previous measurement while layout/window changes settle.
			publish(nil)
			return
		}
		publish(WindowFrameAnchor(frame: frame, windowID: ObjectIdentifier(window)))
	}

	private func publish(_ anchor: WindowFrameAnchor?) {
		guard anchor != lastAnchor else { return }
		lastAnchor = anchor
		let token = generation
		let expectedWindowID = window.map(ObjectIdentifier.init)
		DispatchQueue.main.async { [weak self] in
			guard let self, self.generation == token,
				self.window.map(ObjectIdentifier.init) == expectedWindowID,
				self.lastAnchor == anchor else { return }
			self.onChange?(anchor)
		}
	}

	func invalidate() {
		generation += 1
		onChange = nil
		lastAnchor = nil
	}
}

@MainActor
final class SearchOverlayLayout: ObservableObject {
	@Published var barAnchor: WindowFrameAnchor?
}

struct SearchOverlaySurface: View {
	@Binding var text: String
	var focus: Binding<Bool>
	let title: String
	@ObservedObject var transition: SearchToolbarTransition
	@ObservedObject var layout: SearchOverlayLayout
	let sourceAnchor: WindowFrameAnchor?
	let searchFieldOwner: SearchTextFieldOwner
	let searchInTitle: Bool
	var titleIsLeading = false
	let rightToLeft: Bool
	let isScreenActive: Bool

	var body: some View {
		GeometryReader { geometry in
			let width = max(44, min(600, geometry.size.width - 84))
			let final = CGRect(x: rightToLeft ? geometry.size.width - 16 - width : 16,
				y: (geometry.size.height - 40) / 2, width: width, height: 40)
			let fallbackX = searchInTitle
				? (titleIsLeading ? (rightToLeft ? geometry.size.width - 38 : 38) : geometry.size.width / 2)
				: (rightToLeft ? 38 : geometry.size.width - 38)
			let source: CGPoint = {
				guard let sourceAnchor, let barAnchor = layout.barAnchor,
					sourceAnchor.windowID == barAnchor.windowID else {
					return CGPoint(x: fallbackX, y: geometry.size.height / 2)
				}
				return CGPoint(x: sourceAnchor.frame.midX - barAnchor.frame.minX,
					y: sourceAnchor.frame.midY - barAnchor.frame.minY)
			}()
			HStack(spacing: 8) {
				Image(systemName: "magnifyingglass")
					.font(.system(size: 16)).foregroundStyle(.secondary)
				KeyboardSearchField(text: $text, focus: focus,
					prompt: .localized("Search %@", arguments: title), transition: transition,
					fieldOwner: searchFieldOwner, isScreenActive: isScreenActive)
					.tint(.primary)
			}
			.padding(.horizontal, 12)
			.frame(width: transition.expanded ? final.width : 44,
				height: transition.expanded ? final.height : 44)
			.clipped()
			.glassEffect(.regular.interactive(), in: .capsule)
			.position(CGPoint(
				x: transition.expanded ? final.midX : source.x,
				y: transition.expanded ? final.midY : source.y
			))
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
	let searchFieldOwner = SearchTextFieldOwner()
	private var host: UIView?
	private weak var bar: UINavigationBar?
	private let touchContainer = SearchOverlayTouchView()
	private var barAnchorGeneration = 0
	// Visibility belongs to the active route, independently of the retained search session.
	var isScreenActive = true {
		didSet {
			guard oldValue != isScreenActive else { return }
			if isScreenActive {
				searchFieldOwner.setScreenActive(true)
				touchContainer.isHidden = false
				attachIfNeeded()
			} else {
				deactivateAndDetach()
			}
		}
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
		if window == nil { detachFromNavigationBar() }
		else if isScreenActive { attachIfNeeded() }
	}

	override func layoutSubviews() {
		super.layoutSubviews()
		guard isScreenActive else { return }
		attachIfNeeded()
		updateBarAnchor()
	}

	func attachIfNeeded() {
		guard isScreenActive, let window, let host else { return }
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
		guard let owner, let target = owner.navigationController?.navigationBar,
			target.window === window else { return }
		if bar !== target || touchContainer.superview !== target {
			detachFromNavigationBar()
			bar = target
			touchContainer.frame = target.bounds
			touchContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
			if host.superview !== touchContainer {
				host.frame = touchContainer.bounds
				host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
				touchContainer.addSubview(host)
			}
			touchContainer.isHidden = false
			target.addSubview(touchContainer)
		}
		updateBarAnchor()
	}

	private func updateBarAnchor() {
		guard isScreenActive, let bar, let window, bar.window === window else { return }
		let frame = bar.convert(bar.bounds, to: window)
		let anchor = WindowFrameAnchor(frame: frame, windowID: ObjectIdentifier(window))
		guard anchor != layout.barAnchor else { return }
		barAnchorGeneration += 1
		let generation = barAnchorGeneration
		DispatchQueue.main.async { [weak self] in
			guard let self, self.isScreenActive, self.bar === bar,
				self.window === window, self.barAnchorGeneration == generation,
				self.layout.barAnchor != anchor else { return }
			self.layout.barAnchor = anchor
		}
	}

	func deactivateAndDetach() {
		acceptsSearchTouches = false
		touchContainer.acceptsSearchTouches = false
		touchContainer.isHidden = true
		searchFieldOwner.setScreenActive(false)
		detachFromNavigationBar()
	}

	func detachFromNavigationBar() {
		barAnchorGeneration += 1
		touchContainer.acceptsSearchTouches = false
		touchContainer.isHidden = true
		touchContainer.removeFromSuperview()
		bar = nil
	}

	func tearDown() {
		isScreenActive = false
		deactivateAndDetach()
		searchFieldOwner.prepareForRemoval()
		host?.removeFromSuperview()
		host = nil
		surface = nil
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
