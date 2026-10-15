import SwiftUI

public extension View {
	func nbSectionHeaderFont(weight: Font.Weight = .bold) -> some View {
		modifier(NBSectionHeaderFont(weight: weight))
	}
}

private struct NBSectionHeaderFont: ViewModifier {
	@AppStorage("Aether.sectionHeaderMatchesPageTitle") private var matchesPageTitle = false
	let weight: Font.Weight

	func body(content: Content) -> some View {
		content.font(matchesPageTitle ? .headline.weight(weight) : .title3.weight(weight))
	}
}
