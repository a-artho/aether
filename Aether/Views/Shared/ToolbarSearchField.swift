import SwiftUI

struct ToolbarSearchField: View {
	@Binding var text: String
	@Binding var isPresented: Bool
	var focus: FocusState<Bool>.Binding
	let prompt: String

	var body: some View {
		HStack(spacing: 8) {
			Image(systemName: "magnifyingglass")
				.font(.system(size: 15, weight: .semibold))
				.foregroundColor(.secondary)
				.padding(.leading, 12)

			TextField(prompt, text: $text)
				.font(.system(size: 16))
				.focused(focus)
				.textInputAutocapitalization(.never)
				.disableAutocorrection(true)
				.onAppear {
					DispatchQueue.main.async {
						guard isPresented else { return }
						focus.wrappedValue = true
					}
				}

			if !text.isEmpty {
				Button {
					text = ""
				} label: {
					Image(systemName: "xmark.circle.fill")
						.font(.system(size: 14))
						.foregroundColor(.secondary)
				}
				.buttonStyle(.plain)
				.padding(.trailing, 8)
			}
		}
		.frame(height: 36)
		.frame(width: min(500, UIScreen.main.bounds.width - 74))
		.background {
			Color.clear.glassEffect(.regular, in: .capsule)
		}
	}
}
