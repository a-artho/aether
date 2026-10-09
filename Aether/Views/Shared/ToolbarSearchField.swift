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
	var isScreenActive = true
	var searchOnLeading = true
	var hasTitleMenu = true
	var secondarySymbol = "plus"
	var secondaryLabel = String.localized("Add")
	var secondaryAction: (() -> Void)?
	var secondaryURLAction: (() -> Void)? = nil
	@ViewBuilder var titleMenu: () -> MenuContent
	@StateObject private var transition = SearchToolbarTransition()
	@State private var searchButtonFrame: CGRect = .zero
	@AppStorage("Aether.searchOnRight") private var searchOnRight = false

	private var usesLeadingSearch: Bool { searchOnLeading && !searchOnRight }

	func body(content: Content) -> some View {
		content
			.navigationTitle(title)
			.navigationBarTitleDisplayMode(.inline)
			.navigationBarBackButtonHidden(transition.expanded)
			.toolbar {
				if enabled {
					ToolbarItem(placement: .principal) {
						Group {
							if hasTitleMenu {
								Menu { titleMenu() } label: {
									HStack(spacing: 8) {
										Text(title).font(.headline).lineLimit(1)
										Image(systemName: "chevron.down")
											.font(.system(size: 10, weight: .semibold))
											.foregroundStyle(.secondary)
											.frame(width: 18, height: 18)
											.glassEffect(.regular.interactive(), in: .circle)
									}
									.accessibilityHidden(transition.expanded)
								}
								.buttonStyle(.plain)
								.menuIndicator(.hidden)
								.accessibilityLabel(title)
								.accessibilityHidden(transition.expanded)
							} else {
								Text(title).font(.headline).lineLimit(1)
							}
						}
						// Preserve the complete title label's width throughout search.
						// The menu indicator must share the title's visibility and timing.
						.opacity(transition.expanded ? 0 : 1)
						.scaleEffect(transition.expanded ? 0.9 : 1)
						.animation(transition.animation, value: transition.expanded)
						.allowsHitTesting(!transition.expanded)
						.accessibilityHidden(transition.expanded)
					}
					.sharedBackgroundVisibility(.hidden)
					if !usesLeadingSearch && secondaryAction != nil {
						ToolbarItemGroup(placement: .topBarTrailing) {
							if !transition.expanded { searchButton }
							secondaryButton
						}
					} else {
						ToolbarItem(id: "search-action", placement: usesLeadingSearch ? .topBarLeading : .topBarTrailing) {
							searchButton
						}
						.sharedBackgroundVisibility(usesLeadingSearch && transition.expanded ? .hidden : .automatic)
						if usesLeadingSearch {
							ToolbarItem(id: "search-secondary", placement: .topBarTrailing) {
								secondaryButton
							}
						}
					}
				}
			}
			.background {
				if enabled {
					SearchHeaderOverlay(text: $text, focus: focus, title: title,
						transition: transition, sourceFrame: searchButtonFrame, searchOnLeading: usesLeadingSearch,
						isScreenActive: isScreenActive)
				}
			}
			.onAppear { transition.restore(isPresented: isPresented) }
			.onChange(of: isPresented) { _, presented in transition.setPresented(presented, keyboardExpected: focus.wrappedValue) }
			.onScrollPhaseChange { _, phase in
				if phase == .interacting { focus.wrappedValue = false }
			}
	}
	private var searchButton: some View {
		Button {
			if transition.expanded && !usesLeadingSearch { closeSearch() }
			else { openSearch() }
		} label: {
			Image(systemName: transition.expanded && !usesLeadingSearch ? "xmark" : "magnifyingglass")
		}
		.opacity(usesLeadingSearch && transition.expanded ? 0 : 1)
		.allowsHitTesting(!usesLeadingSearch || !transition.expanded)
		.accessibilityHidden(usesLeadingSearch && transition.expanded)
		.accessibilityLabel(transition.expanded && !usesLeadingSearch ? String.localized("Cancel") : String.localized("Search"))
		.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
			if !transition.expanded { searchButtonFrame = frame }
		}
	}

	private var secondaryButton: some View {
		Button {
			if transition.expanded { closeSearch() }
			else { secondaryAction?() }
		} label: { Image(systemName: transition.expanded ? "xmark" : secondarySymbol) }
			.accessibilityLabel(transition.expanded ? .localized("Cancel") : secondaryLabel)
			.opacity(secondaryAction != nil || transition.expanded ? 1 : 0)
			.allowsHitTesting(secondaryAction != nil || transition.expanded)
			.highPriorityGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
				guard !transition.expanded, let secondaryURLAction else { return }
				HapticManager.shared.impact()
				secondaryURLAction()
			}, including: secondaryURLAction == nil || transition.expanded ? .none : .all)
	}

	private func openSearch() {
		focus.wrappedValue = true
		transition.setPresented(true)
		isPresented = true
	}

	private func closeSearch() {
		transition.setPresented(false, keyboardExpected: focus.wrappedValue)
		focus.wrappedValue = false
		isPresented = false
	}

}

@MainActor
final class SearchToolbarTransition: ObservableObject {
	@Published private(set) var expanded = false
	private(set) var requested = false
	private(set) var animationDuration = 0.25
	private(set) var animation: Animation? = .easeInOut(duration: 0.25)
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

	func keyboardWillChange(duration: Double, curve: UInt) {
		guard waitingForKeyboard else { return }
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
		self.animation = UIAccessibility.isReduceMotionEnabled ? nil : animation
		withAnimation(self.animation) {
			expanded = requested
		}
	}
}

struct KeyboardSearchField: UIViewRepresentable {
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
		field.keyboardChanged = { [weak transition] duration, curve in
			transition?.keyboardWillChange(duration: duration, curve: curve)
		}
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

final class SearchTextField: UITextField, UITextFieldDelegate {
	var wantsFocus = false
	var textChanged: ((String) -> Void)?
	var focusChanged: ((Bool) -> Void)?
	var keyboardChanged: ((Double, UInt) -> Void)?
	private var keyboardObserver: NSObjectProtocol?

	override init(frame: CGRect) {
		super.init(frame: frame)
		delegate = self
		addTarget(self, action: #selector(editingChanged), for: .editingChanged)
		keyboardObserver = NotificationCenter.default.addObserver(
			forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main
		) { [weak self] notification in
			let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
			let curve = notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 0
			MainActor.assumeIsolated { self?.keyboardChanged?(duration, curve) }
		}
	}
	required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
	isolated deinit { if let keyboardObserver { NotificationCenter.default.removeObserver(keyboardObserver) } }
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
