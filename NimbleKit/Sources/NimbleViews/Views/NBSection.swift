//
//  SectionProminentHeaderWrapper.swift
//  Aether
//
//  Created by samara on 11.04.2025.
//

import SwiftUI

public struct NBSection<Content, Footer>: View
	where 	Content: View,
	Footer: View
{
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	private var _isExpanded: Binding<Bool>?
	private var _headerText: String
	private var _headerTextSecondary: String?
	private var _systemName: String?
	private var _trailing: AnyView?
	private var _content: Content
	private var _footer: Footer

	public init(_ headerText: String,
	            secondary headerTextSecondary: String? = nil,
	            systemName: String? = nil,
	            isExpanded: Binding<Bool>? = nil,
	            @ViewBuilder content: () -> Content,
	            @ViewBuilder footer: () -> Footer
	) {
		self._isExpanded = isExpanded
		self._headerText = headerText
		self._headerTextSecondary = headerTextSecondary
		self._systemName = systemName
		self._trailing = nil
		self._content = content()
		self._footer = footer()
	}

	public init(_ headerText: String,
	            secondary headerTextSecondary: String? = nil,
	            systemName: String? = nil,
	            isExpanded: Binding<Bool>? = nil,
	            @ViewBuilder content: () -> Content
	) where Footer == EmptyView {
		self._isExpanded = isExpanded
		self._headerText = headerText
		self._headerTextSecondary = headerTextSecondary
		self._systemName = systemName
		self._trailing = nil
		self._content = content()
		self._footer = EmptyView()
	}

	public init<Trailing: View>(
		_ headerText: String,
		systemName: String? = nil,
	            isExpanded: Binding<Bool>? = nil,
		@ViewBuilder trailing: () -> Trailing,
		@ViewBuilder content: () -> Content,
		@ViewBuilder footer: () -> Footer
	) {
		self._isExpanded = isExpanded
		self._headerText = headerText
		self._headerTextSecondary = nil
		self._systemName = systemName
		self._trailing = AnyView(trailing())
		self._content = content()
		self._footer = footer()
	}

	public init<Trailing: View>(
		_ headerText: String,
		systemName: String? = nil,
	            isExpanded: Binding<Bool>? = nil,
		@ViewBuilder trailing: () -> Trailing,
		@ViewBuilder content: () -> Content
	) where Footer == EmptyView {
		self._isExpanded = isExpanded
		self._headerText = headerText
		self._headerTextSecondary = nil
		self._systemName = systemName
		self._trailing = AnyView(trailing())
		self._content = content()
		self._footer = EmptyView()
	}

	@ViewBuilder private var header: some View {
		if let expanded = _isExpanded {
			Button {
				withAnimation(reduceMotion ? nil : .snappy) { expanded.wrappedValue.toggle() }
			} label: { headerLabel }
			.buttonStyle(.plain)
			.accessibilityValue(expanded.wrappedValue ? String(localized: "Expanded") : String(localized: "Collapsed"))
		} else { headerLabel }
	}

	private var headerLabel: some View {
			HStack(alignment: .center, spacing: 4) {
				if let _systemName {
					Image(systemName: _systemName)
						.font(.system(size: 12))
						.offset(y: -2)
				}

				Text(_headerText)
					.fontWeight(.bold)
					.font(.title3)
					.nbSectionHeaderColor()

				Spacer()

				if let _trailing {
					_trailing
				} else if let _headerTextSecondary, _isExpanded?.wrappedValue == false {
					Text(_headerTextSecondary)
						.font(.caption)
						.foregroundStyle(.secondary)
						.contentTransition(.numericText())
				}
			}
			.padding(.trailing, _isExpanded == nil ? 0 : 22)
			.overlay(alignment: .trailing) {
				if let expanded = _isExpanded {
					Image(systemName: "chevron.down")
						.font(.caption.weight(.semibold))
						.foregroundStyle(.secondary)
						.rotationEffect(.degrees(expanded.wrappedValue ? 0 : -90))
						.accessibilityHidden(true)
				}
			}
			.contentShape(Rectangle())
	}

	public var body: some View {
		Section(header: header.offset(y: 2), footer: _footer.font(.caption).foregroundStyle(.secondary)) {
			if _isExpanded?.wrappedValue != false { _content }
		}
		.headerProminence(.increased)
	}
}
