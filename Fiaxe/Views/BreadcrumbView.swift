import SwiftUI

/// Displays a clickable path breadcrumb: Bucket > folder > subfolder > current
struct BreadcrumbView: View {
    let bucketName: String
    /// Ordered path segments (e.g. ["photos", "vacation"] for prefix "photos/vacation/")
    let segments: [String]
    /// Called when the user taps a segment to navigate to it.
    /// Index -1 = root (bucket level), 0..n-1 = segment index
    let onNavigate: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                // Root bucket button
                Button {
                    onNavigate(-1)
                } label: {
                    Label(bucketName, systemImage: "externaldrive.fill")
                        .foregroundStyle(.blue)
                        .fontWeight(segments.isEmpty ? .bold : .regular)
                }
                .buttonStyle(.plain)

                // Intermediate segments (clickable)
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    chevron
                    if index < segments.count - 1 {
                        Button {
                            onNavigate(index)
                        } label: {
                            Text(segment)
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                    } else {
                        // Current (deepest) segment — bold, non-clickable
                        Text(segment)
                            .fontWeight(.bold)
                            .foregroundStyle(.primary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

#Preview {
    VStack(spacing: 0) {
        BreadcrumbView(
            bucketName: "my-bucket",
            segments: ["photos", "vacation"],
            onNavigate: { _ in }
        )
        Divider()
        BreadcrumbView(
            bucketName: "my-bucket",
            segments: [],
            onNavigate: { _ in }
        )
    }
    .frame(width: 400)
}
