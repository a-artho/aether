import SwiftUI
import UIKit

enum SearchPlacement: String, CaseIterable, Identifiable {
	case right, pageTitle

	var id: Self { self }
	var label: String {
		switch self {
		case .right: .localized("Right")
		case .pageTitle: .localized("Page Title")
		}
	}
}

/// Applies the native iOS 26 soft scroll-edge treatment to a navigation stack.
struct FloatingNavigationAppearance: ViewModifier {
	func body(content: Content) -> some View {
		content.scrollEdgeEffectStyle(.soft, for: .top)
	}
}

/// Native navigation items when idle; SwiftUI owns the expanding search surface.
/// The text-field bridge supplies the keyboard's timing and reliable responder focus.
struct SearchToolbarModifier<MenuContent: View>: ViewModifier {
	@Binding var text: String
	@Binding var isPresented: Bool
	var focus: Binding<Bool>
	let title: String
	var enabled = true
	var isScreenActive = true
	var isTabRoot = false
	var hasTitleMenu = true
	var hasTitleSearchMenu = false
	var secondarySymbol = "plus"
	var secondaryLabel = String.localized("Add")
	var secondaryAction: (() -> Void)?
	var secondaryURLAction: (() -> Void)? = nil
	@ViewBuilder var titleMenu: () -> MenuContent
	@StateObject private var transition = SearchToolbarTransition()
	@State private var searchButtonAnchor: WindowFrameAnchor?
	@AppStorage("Aether.searchPlacement") private var searchPlacement: SearchPlacement = .right
	@AppStorage("Aether.leadingPageTitles") private var leadingPageTitles = false

	private var usesTitleSearch: Bool { searchPlacement == .pageTitle }
	private var hidesTitle: Bool { isTabRoot && !usesTitleSearch }
	private var usesLeadingTitle: Bool { isTabRoot && usesTitleSearch && leadingPageTitles }
	// Different navigation actions need distinct identities for the native handoff.
	// Keep each identity stable while its button becomes the search-close control.
	private var secondaryToolbarID: String { hasTitleSearchMenu ? "navigation-filter" : "navigation-add" }

	func body(content: Content) -> some View {
		content
			.scrollDismissesKeyboard(.immediately)
			.navigationTitle(hidesTitle || usesLeadingTitle ? "" : title)
			.navigationBarTitleDisplayMode(.inline)
			.navigationBarBackButtonHidden(transition.expanded)
			.toolbar {
				if enabled {
					if usesLeadingTitle {
						ToolbarItem(id: "page-title-leading", placement: .topBarLeading) {
							titleLabel.fixedSize(horizontal: true, vertical: false)
						}
						.sharedBackgroundVisibility(.hidden)
						// Override the native center title without reserving its text width.
						ToolbarItem(id: "page-title-center-placeholder", placement: .principal) {
							Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
						}
						.sharedBackgroundVisibility(.hidden)
					} else {
						ToolbarItem(id: "page-title", placement: .principal) { titleLabel }
							.sharedBackgroundVisibility(.hidden)
					}
					if usesTitleSearch {
						if transition.expanded || secondaryAction != nil || hasTitleSearchMenu {
							ToolbarItem(id: secondaryToolbarID, placement: .topBarTrailing) {
								secondaryButton
							}
						}
					} else {
						// Match the search item's identity across root and pushed pages.
						// Consecutive trailing items share the system glass background.
						if secondaryAction == nil || !transition.expanded {
							ToolbarItem(id: "search-action", placement: .topBarTrailing) {
								searchButton
							}
						}
						if secondaryAction != nil {
							ToolbarItem(id: "navigation-add", placement: .topBarTrailing) {
								secondaryButton
							}
						}
					}
				}
			}
			.background {
				if enabled {
					SearchHeaderOverlay(text: $text, focus: focus, title: title,
					transition: transition, sourceAnchor: searchButtonAnchor,
					searchInTitle: usesTitleSearch, titleIsLeading: usesLeadingTitle,
					isScreenActive: isScreenActive)
				}
			}
			.onAppear { transition.restore(isPresented: isPresented) }
			.onChange(of: isScreenActive) { _, active in
				if active { transition.restore(isPresented: isPresented) }
				else {
					focus.wrappedValue = false
					transition.cancelPendingKeyboardTransition()
				}
			}
			.onChange(of: searchPlacement) { _, _ in searchButtonAnchor = nil }
			.onChange(of: leadingPageTitles) { _, _ in searchButtonAnchor = nil }
			.onChange(of: isPresented) { _, presented in transition.setPresented(presented, keyboardExpected: focus.wrappedValue) }
			.onScrollPhaseChange { _, phase in
				if phase == .interacting { focus.wrappedValue = false }
			}
	}
	private var titleLabel: some View {
		Group {
			if usesTitleSearch {
				Button(action: openSearch) {
					Text(title).font(.headline).foregroundStyle(.primary).lineLimit(1)
					.frame(minHeight: 44)
					.contentShape(Rectangle())
					.background {
						WindowFrameReader { anchor in
							guard isScreenActive, !transition.requested, !transition.expanded else { return }
							searchButtonAnchor = anchor
						}
					}
				}
				.buttonStyle(.plain)
				.accessibilityLabel(String.localized("Search %@", arguments: title))
			} else if hasTitleMenu {
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
		.opacity(hidesTitle || transition.expanded ? 0 : 1)
		.scaleEffect(transition.expanded ? 0.9 : 1)
		.animation(transition.animation, value: transition.expanded)
		.allowsHitTesting(!hidesTitle && !transition.expanded)
		.accessibilityHidden(hidesTitle || transition.expanded)
	}

	private var searchButton: some View {
		Button {
			if transition.expanded { closeSearch() }
			else { openSearch() }
		} label: {
			Image(systemName: transition.expanded ? "xmark" : "magnifyingglass")
		}
		.accessibilityLabel(transition.expanded ? String.localized("Cancel") : String.localized("Search"))
		.background {
			WindowFrameReader { anchor in
				guard isScreenActive, !transition.expanded else { return }
				searchButtonAnchor = anchor
			}
		}
	}

	@ViewBuilder private var secondaryButton: some View {
		if hasTitleSearchMenu && usesTitleSearch && !transition.expanded {
			Menu { titleMenu() } label: { Image(systemName: secondarySymbol) }
				.accessibilityLabel(secondaryLabel)
		} else {
			Button {
				if transition.expanded { closeSearch() }
				else { secondaryAction?() }
			} label: { Image(systemName: transition.expanded ? "xmark" : secondarySymbol) }
				.accessibilityLabel(transition.expanded ? .localized("Cancel") : secondaryLabel)
				.opacity(secondaryAction != nil || transition.expanded ? 1 : 0)
				.allowsHitTesting(secondaryAction != nil || transition.expanded)
				.accessibilityHidden(secondaryAction == nil && !transition.expanded)
				.highPriorityGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
					guard !transition.expanded, let secondaryURLAction else { return }
					HapticManager.shared.impact()
					secondaryURLAction()
				}, including: secondaryURLAction == nil || transition.expanded ? .none : .all)
		}
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

	func cancelPendingKeyboardTransition() {
		generation += 1
		waitingForKeyboard = false
	}

	var isWaitingForKeyboard: Bool { waitingForKeyboard }

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
	let isScreenActive: Bool

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
		field.setScreenActive(isScreenActive)
		field.textChanged = { text = $0 }
		field.focusChanged = { focus.wrappedValue = $0 }
		field.keyboardChanged = { [weak transition, weak field] duration, curve in
			guard let field, field.isScreenActive,
				field.isFirstResponder || field.hasKeyboardSession,
				transition?.isWaitingForKeyboard == true else { return }
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
		field.prepareForRemoval()
	}
}

final class SearchTextField: UITextField, UITextFieldDelegate {
	var wantsFocus = false
	var textChanged: ((String) -> Void)?
	var focusChanged: ((Bool) -> Void)?
	var keyboardChanged: ((Double, UInt) -> Void)?
	private var keyboardObserver: NSObjectProtocol?
	private(set) var isScreenActive = false
	private(set) var hasKeyboardSession = false

	override init(frame: CGRect) {
		super.init(frame: frame)
		delegate = self
		addTarget(self, action: #selector(editingChanged), for: .editingChanged)
	}
	required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
	isolated deinit { removeKeyboardObserver() }
	override func didMoveToWindow() {
		super.didMoveToWindow()
		updateKeyboardObserver()
		updateFocus()
	}
	func setScreenActive(_ active: Bool) {
		guard isScreenActive != active else { return }
		isScreenActive = active
		if !active {
			hasKeyboardSession = false
			if isFirstResponder { resignFirstResponder() }
		}
		updateKeyboardObserver()
	}
	func prepareForRemoval() {
		setScreenActive(false)
		focusChanged = nil
		keyboardChanged = nil
		textChanged = nil
		if isFirstResponder { resignFirstResponder() }
		removeKeyboardObserver()
	}
	func updateFocus() {
		guard window != nil else { return }
		if wantsFocus && isScreenActive && !isFirstResponder { becomeFirstResponder() }
		else if !wantsFocus && isFirstResponder { resignFirstResponder() }
	}
	@objc private func editingChanged() { textChanged?(text ?? "") }
	func textFieldShouldReturn(_ textField: UITextField) -> Bool { resignFirstResponder(); return true }
	func textFieldDidBeginEditing(_ textField: UITextField) { hasKeyboardSession = true; publishFocus() }
	func textFieldDidEndEditing(_ textField: UITextField) {
		if isScreenActive { hasKeyboardSession = true }
		publishFocus()
	}
	private func updateKeyboardObserver() {
		guard isScreenActive, window != nil else {
			removeKeyboardObserver()
			return
		}
		guard keyboardObserver == nil else { return }
		keyboardObserver = NotificationCenter.default.addObserver(
			forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main
		) { [weak self] notification in
			let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
			let curve = notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 0
			MainActor.assumeIsolated {
				guard let self, self.isScreenActive,
					self.isFirstResponder || self.hasKeyboardSession else { return }
				self.keyboardChanged?(duration, curve)
				self.hasKeyboardSession = false
			}
		}
	}
	private func removeKeyboardObserver() {
		guard let keyboardObserver else { return }
		NotificationCenter.default.removeObserver(keyboardObserver)
		self.keyboardObserver = nil
	}
	private func publishFocus() {
		DispatchQueue.main.async { [weak self] in
			guard let self else { return }
			self.focusChanged?(self.isFirstResponder)
		}
	}
}
