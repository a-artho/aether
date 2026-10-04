import ActivityKit
import SwiftUI
import WidgetKit

@main
struct AetherDownloadActivityBundle: WidgetBundle {
    var body: some Widget { DownloadActivityWidget() }
}

private struct DownloadActivityWidget: Widget {

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            let tint = activityTint(context.attributes.tintHex)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: context.state.status.symbol).foregroundStyle(tint)
                    Text(context.attributes.appName).font(.headline).lineLimit(1)
                    Spacer()
                    Text(LocalizedStringKey(context.state.status.label)).font(.caption).foregroundStyle(.secondary)
                }
                if context.state.status == .downloading {
                    if let progress = context.state.fractionCompleted {
                        ProgressView(value: progress).tint(tint)
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().tint(tint)
                            Text(context.state.byteSummary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if context.state.fractionCompleted != nil {
                        Text(context.state.byteSummary).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
            .activityBackgroundTint(Color(.secondarySystemBackground))
            .activitySystemActionForegroundColor(tint)
            .widgetURL(URL(string: "aether://tab?name=library"))
        } dynamicIsland: { context in
            let tint = activityTint(context.attributes.tintHex)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { indicator(context.state, tint: tint) }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(LocalizedStringKey(context.state.status.label)).font(.caption)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.attributes.appName).font(.headline).lineLimit(1)
                        if context.state.status == .downloading {
                            if let progress = context.state.fractionCompleted {
                                ProgressView(value: progress).tint(tint)
                            }
                            Text(context.state.byteSummary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.status.symbol).foregroundStyle(tint)
            } compactTrailing: {
                indicator(context.state, tint: tint)
            } minimal: {
                indicator(context.state, tint: tint)
            }
            .keylineTint(tint)
            .widgetURL(URL(string: "aether://tab?name=library"))
        }
    }

    private func activityTint(_ hex: String) -> Color {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x848ef9
        return Color(red: Double((value >> 16) & 255) / 255,
            green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }

    @ViewBuilder
    private func indicator(_ state: DownloadActivityAttributes.ContentState, tint: Color) -> some View {
        if state.status == .downloading {
            if let progress = state.fractionCompleted {
                ZStack {
                    Circle().stroke(tint.opacity(0.25), lineWidth: 2)
                    Circle().trim(from: 0, to: progress).stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }.frame(width: 18, height: 18)
            } else {
                ProgressView().tint(tint)
            }
        } else {
            Image(systemName: state.status.symbol).foregroundStyle(tint)
        }
    }
}
