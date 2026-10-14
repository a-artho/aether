import SwiftUI

/// Shared pill for repository date/name groups and available update dates.
struct SourceAppDateChip: View {
    let title: String
    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Text(verbatim: title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .glassEffect(.regular, in: .capsule)
            Spacer(minLength: 0)
        }
        .textCase(nil)
    }
}
