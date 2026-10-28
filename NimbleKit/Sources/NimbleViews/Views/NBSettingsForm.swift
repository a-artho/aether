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
						VStack(spacing: 0) {
							ForEach(section.content) { row in
								if row.id != section.content.first?.id {
									Divider().padding(.leading, 16)
								}
								row
									.buttonStyle(.plain)
									.frame(maxWidth: .infinity, alignment: .leading)
									.padding(.horizontal, row.containerValues.nbSettingsCardOwnPadding ? 0 : 16)
									.padding(.vertical, row.containerValues.nbSettingsCardOwnPadding ? 0 : 11)
									.frame(minHeight: 44)
							}
						}
						.glassEffect(.regular, in: .rect(cornerRadius: 26))
						.listRowInsets(EdgeInsets())
						.listRowBackground(Color.clear)
						.listRowSeparator(.hidden)
						}
					} header: {
						section.header
					} footer: {
						section.footer
					}
				}
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
