import SwiftUI
import UIKit

/// Native navigation items when idle; SwiftUI owns the expanding search surface.
/// The text-field bridge supplies the keyboard's timing and reliable responder focus.
struct SearchToolbarModifier<MenuContent: View>: ViewModifier {
	@Binding var text: String
	@Binding var isPresented: Bool
	var focus: Binding<Bool>
	let title: String
	let width: CGFloat
	var enabled = true
	var searchOnLeading = true
	var hasTitleMenu = true
	var secondarySymbol = "plus"
	var secondaryLabel = String.localized("Add")
	var secondaryAction: (() -> Void)?
	@ViewBuilder var titleMenu: () -> MenuContent
	@StateObject private var transition = SearchToolbarTransition()
	@Namespace private var searchGeometry
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	func body(content: Content) -> some View {
		content
			.navigationTitle(title)
			.navigationBarTitleDisplayMode(.inline)
			.navigationBarBackButtonHidden(transition.expanded)
			.toolbar {
				if enabled {
					ToolbarItem(placement: .principal) {
						ZStack {
							Text(title)
								.font(.headline).lineLimit(1)
								.opacity(transition.expanded ? 0 : 1)
								.scaleEffect(transition.expanded ? 0.9 : 1)
								.animation(reduceMotion ? nil : .easeInOut(duration: transition.animationDuration), value: transition.expanded)
								.accessibilityHidden(transition.expanded)
							HStack(spacing: 8) {
								Image(systemName: "magnifyingglass")
									.font(.system(size: 16)).foregroundStyle(.secondary)
								KeyboardSearchField(text: $text, focus: focus,
									prompt: .localized("Search %@", arguments: title),
									transition: transition)
									.tint(.primary)
							}
							.padding(.horizontal, 12)
							.frame(width: transition.expanded ? max(44, min(600, width - 84)) : 40, height: 40)
							.clipped()
							.glassEffect(.regular.interactive(), in: .capsule)
							.matchedGeometryEffect(id: "search", in: searchGeometry, isSource: transition.expanded)
							.opacity(transition.expanded ? 1 : 0)
							.allowsHitTesting(transition.expanded)
							.accessibilityHidden(!transition.expanded)
						}
						.frame(width: transition.expanded ? max(44, min(600, width - 84)) : nil, height: 44)
					}
					.sharedBackgroundVisibility(transition.expanded ? .hidden : .automatic)
					if hasTitleMenu && !transition.expanded {
						ToolbarTitleMenu { titleMenu() }
					}
				}
				if enabled && !transition.expanded {
					ToolbarItem(placement: searchOnLeading ? .topBarLeading : .topBarTrailing) {
						Button {
							focus.wrappedValue = true
							transition.setPresented(true)
							isPresented = true
						} label: { Image(systemName: "magnifyingglass") }
						.matchedGeometryEffect(id: "search", in: searchGeometry, isSource: !transition.expanded)
						.accessibilityLabel(.localized("Search"))
					}
					if let secondaryAction {
						ToolbarItem(placement: .topBarTrailing) {
							Button(action: secondaryAction) { Image(systemName: secondarySymbol) }
								.accessibilityLabel(secondaryLabel)
						}
					}
				} else if enabled {
					ToolbarItem(placement: .topBarTrailing) {
						Button {
							transition.setPresented(false, keyboardExpected: focus.wrappedValue)
							focus.wrappedValue = false
							isPresented = false
						} label: { Image(systemName: "xmark") }
							.accessibilityLabel(.localized("Cancel"))
					}
				}
			}
			.onAppear { transition.restore(isPresented: isPresented) }
			.onChange(of: isPresented) { transition.setPresented($0, keyboardExpected: focus.wrappedValue) }
	}
}

@MainActor
final class SearchToolbarTransition: ObservableObject {
	@Published private(set) var expanded = false
	private(set) var requested = false
	private(set) var animationDuration = 0.25
	private var waitingForKeyboard = false
	private var generation = 0

	func restore(isPresented: Bool) {
		// Returning from details retains search without requesting the keyboard again.
		generation += 1
		requested = isPresented
		expanded = isPresented
		waitingForKeyboard = false
	}

	func setPresented(_ presented: Bool, keyboardExpected: Bool = true) {
		guard requested != presented else { return }
		generation += 1
		requested = presented
		waitingForKeyboard = true
		if !presented && !keyboardExpected {
			animate(duration: 0.25, curve: 0)
			return
		}
		// Hardware keyboards and already-dismissed keyboards may send no notification.
		let token = generation
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
			guard let self, self.generation == token, self.waitingForKeyboard else { return }
			self.animate(duration: 0.25, curve: 0)
		}
	}

	func keyboardWillChange(_ notification: Notification) {
		guard waitingForKeyboard, let info = notification.userInfo else { return }
		let duration = info[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
		let curve = info[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 0
		waitingForKeyboard = false
		let token = generation
		// Responder changes can deliver this notification inside updateUIView.
		// Publish on the next main-queue turn, before the next rendered frame.
		DispatchQueue.main.async { [weak self] in
			guard let self, self.generation == token else { return }
			self.animate(duration: duration > 0 ? duration : 0.25, curve: curve)
		}
	}

	private func animate(duration: Double, curve: UInt) {
		animationDuration = duration
		waitingForKeyboard = false
		let animation: Animation
		switch curve {
		case 1: animation = .easeIn(duration: duration)
		case 2: animation = .easeOut(duration: duration)
		case 3: animation = .linear(duration: duration)
		case 7: animation = .interpolatingSpring(duration: duration, bounce: 0)
		default: animation = .easeInOut(duration: duration)
		}
		withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : animation) {
			expanded = requested
		}
	}
}

private struct KeyboardSearchField: UIViewRepresentable {
	@Binding var text: String
	var focus: Binding<Bool>
	let prompt: String
	@ObservedObject var transition: SearchToolbarTransition

	func makeUIView(context: Context) -> SearchTextField {
		let field = SearchTextField()
		field.font = .systemFont(ofSize: 16)
		field.textColor = .label
		field.tintColor = .label
		field.autocapitalizationType = .none
		field.autocorrectionType = .no
		field.returnKeyType = .search
		field.clearButtonMode = .always
		field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		return field
	}

	func updateUIView(_ field: SearchTextField, context: Context) {
		field.textChanged = { text = $0 }
		field.focusChanged = { focus.wrappedValue = $0 }
		field.keyboardChanged = { [weak transition] in transition?.keyboardWillChange($0) }
		if field.text != text { field.text = text }
		if field.attributedPlaceholder?.string != prompt {
			field.attributedPlaceholder = NSAttributedString(string: prompt, attributes: [
				.foregroundColor: UIColor.placeholderText
			])
		}
		field.isAccessibilityElement = transition.expanded
		field.accessibilityElementsHidden = !transition.expanded
		field.wantsFocus = transition.requested && focus.wrappedValue
		field.updateFocus()
	}

	static func dismantleUIView(_ field: SearchTextField, coordinator: ()) {
		field.focusChanged = nil
		field.keyboardChanged = nil
		field.resignFirstResponder()
	}
}

private final class SearchTextField: UITextField, UITextFieldDelegate {
	var wantsFocus = false
	var textChanged: ((String) -> Void)?
	var focusChanged: ((Bool) -> Void)?
	var keyboardChanged: ((Notification) -> Void)?
	private var keyboardObserver: NSObjectProtocol?

	override init(frame: CGRect) {
		super.init(frame: frame)
		delegate = self
		addTarget(self, action: #selector(editingChanged), for: .editingChanged)
		keyboardObserver = NotificationCenter.default.addObserver(
			forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main
		) { [weak self] notification in
			MainActor.assumeIsolated { self?.keyboardChanged?(notification) }
		}
	}
	required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
	deinit { if let keyboardObserver { NotificationCenter.default.removeObserver(keyboardObserver) } }
	override func didMoveToWindow() { super.didMoveToWindow(); updateFocus() }
	func updateFocus() {
		guard window != nil else { return }
		if wantsFocus && !isFirstResponder { becomeFirstResponder() }
		else if !wantsFocus && isFirstResponder { resignFirstResponder() }
	}
	@objc private func editingChanged() { textChanged?(text ?? "") }
	func textFieldShouldReturn(_ textField: UITextField) -> Bool { resignFirstResponder(); return true }
	func textFieldDidBeginEditing(_ textField: UITextField) { publishFocus() }
	func textFieldDidEndEditing(_ textField: UITextField) { publishFocus() }
	private func publishFocus() {
		DispatchQueue.main.async { [weak self] in
			guard let self else { return }
			self.focusChanged?(self.isFirstResponder)
		}
	}
}
