import SwiftUI

public extension View {
	func nbSectionHeaderFont() -> some View {
		modifier(NBSectionHeaderFont())
	}
}

private struct NBSectionHeaderFont: ViewModifier {
	@AppStorage("Aether.boldPageAndSectionTitles") private var boldPageAndSectionTitles = true

	func body(content: Content) -> some View {
		content.font(boldPageAndSectionTitles ? .headline.weight(.bold) : .headline)
	}
}
