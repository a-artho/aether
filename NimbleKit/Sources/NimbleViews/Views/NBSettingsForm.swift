import SwiftUI

private struct NBGlassSettingsCardsKey: EnvironmentKey {
	static let defaultValue = false
}

private struct NBSettingsCardOwnSurfaceKey: ContainerValueKey {
	static let defaultValue = false
}

private struct NBSettingsCardOwnPaddingKey: ContainerValueKey {
	static let defaultValue = false
}

public extension ContainerValues {
	var nbSettingsCardOwnSurface: Bool {
		get { self[NBSettingsCardOwnSurfaceKey.self] }
		set { self[NBSettingsCardOwnSurfaceKey.self] = newValue }
	}

	var nbSettingsCardOwnPadding: Bool {
		get { self[NBSettingsCardOwnPaddingKey.self] }
		set { self[NBSettingsCardOwnPaddingKey.self] = newValue }
	}
}

public extension EnvironmentValues {
	var nbGlassSettingsCards: Bool {
		get { self[NBGlassSettingsCardsKey.self] }
		set { self[NBGlassSettingsCardsKey.self] = newValue }
	}
}

// Row bounds describe a shared card without putting multiple controls in one Form row.
private struct NBSettingsCardBounds {
	let sectionID: AnyHashable
	let bounds: Anchor<CGRect>
}

private struct NBSettingsCardBoundsKey: PreferenceKey {
	static let defaultValue: [NBSettingsCardBounds] = []

	static func reduce(value: inout [NBSettingsCardBounds], nextValue: () -> [NBSettingsCardBounds]) {
		value.append(contentsOf: nextValue())
	}
}

/// Keeps the native form unchanged unless Settings explicitly requests glass cards.
public struct NBSettingsForm<Content: View>: View {
	@Environment(\.nbGlassSettingsCards) private var glassCards
	private let content: Content
	private let isList: Bool

	public init(isList: Bool = false, @ViewBuilder content: () -> Content) {
		self.isList = isList
		self.content = content()
	}

	public var body: some View {
		if glassCards {
			Form {
				ForEach(sections: content) { section in
					Section {
						if section.content.first?.containerValues.nbSettingsCardOwnSurface == true {
							section.content
								.listRowInsets(EdgeInsets())
								.listRowBackground(Color.clear)
						} else {
							ForEach(section.content) { row in
								row
									.frame(maxWidth: .infinity, alignment: .leading)
									.padding(.horizontal, row.containerValues.nbSettingsCardOwnPadding ? 0 : 16)
									.padding(.vertical, row.containerValues.nbSettingsCardOwnPadding ? 0 : 11)
									.frame(minHeight: 44)
									.anchorPreference(key: NBSettingsCardBoundsKey.self, value: .bounds) {
										[NBSettingsCardBounds(sectionID: AnyHashable(section.id), bounds: $0)]
									}
									.listRowInsets(EdgeInsets())
									.listRowBackground(Color.clear)
							}
						}
					} header: {
						section.header
					} footer: {
						section.footer
					}
				}
			}
			.scrollContentBackground(.hidden)
			.backgroundPreferenceValue(NBSettingsCardBoundsKey.self) { cards in
				GeometryReader { geometry in
					let groups = Dictionary(grouping: cards, by: \.sectionID)
					ForEach(Array(groups.keys), id: \.self) { sectionID in
						let bounds = groups[sectionID, default: []].reduce(CGRect.null) {
							$0.union(geometry[$1.bounds])
						}
						Color.clear
							.frame(width: bounds.width, height: bounds.height)
							.glassEffect(.regular, in: .rect(cornerRadius: 26))
							.position(x: bounds.midX, y: bounds.midY)
					}
				}
				.clipped()
				.allowsHitTesting(false)
				.accessibilityHidden(true)
			}
			.buttonStyle(.borderless)
			.pickerStyle(.menu)
		} else if isList {
			List { content }
		} else {
			Form { content }
		}
	}
}
