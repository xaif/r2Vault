import SwiftUI

struct UploadHistoryView: View {
    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        if viewModel.historyStore.items.isEmpty {
#if os(iOS)
            iOSEmptyState
#else
            macOSEmptyState
#endif
        } else {
#if os(iOS)
            iOSHistoryList
#else
            macOSHistoryList
#endif
        }
    }

    // MARK: - iOS

#if os(iOS)
    private var iOSEmptyState: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.08))
                    .frame(width: 100, height: 100)
                Circle()
                    .fill(Color.accentColor.opacity(0.06))
                    .frame(width: 72, height: 72)
                Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Color.accentColor.opacity(0.6))
            }

            VStack(spacing: 6) {
                Text("No Upload History")
                    .font(.title3.weight(.semibold))
                Text("Completed uploads will appear here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                viewModel.presentFilePicker()
            } label: {
                Label("Upload Files", systemImage: "arrow.up.circle.fill")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var iOSHistoryList: some View {
        List {
            ForEach(viewModel.historyStore.items) { item in
                IOSHistoryRow(item: item)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            }
            .onDelete { offsets in
                viewModel.historyStore.remove(at: offsets)
            }
        }
        .listStyle(.insetGrouped)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !viewModel.historyStore.items.isEmpty {
                    Menu {
                        Button(role: .destructive) {
                            viewModel.historyStore.clearAll()
                        } label: {
                            Label("Clear All History", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }
#endif

    // MARK: - macOS

#if os(macOS)
    private var macOSEmptyState: some View {
        ContentUnavailableView {
            Label("No Upload History", systemImage: "clock")
        } description: {
            Text("Completed uploads will appear here.")
        } actions: {
            Button {
                viewModel.presentFilePicker()
            } label: {
                Label("Upload Files...", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var macOSHistoryList: some View {
        List {
            ForEach(viewModel.historyStore.items) { item in
                HistoryRowView(item: item)
            }
            .onDelete { offsets in
                viewModel.historyStore.remove(at: offsets)
            }
        }
        .listStyle(.inset)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(role: .destructive) {
                    viewModel.historyStore.clearAll()
                } label: {
                    Label("Clear History", systemImage: "trash")
                }
            }
        }
    }
#endif
}

// MARK: - iOS History Row (modern card-style)

#if os(iOS)
private struct IOSHistoryRow: View {
    let item: UploadItem
    @Environment(AppViewModel.self) private var viewModel
    @State private var showCopied = false

    private var fileExtension: String {
        let components = item.fileName.split(separator: ".")
        return components.count > 1 ? String(components.last!).uppercased() : "FILE"
    }

    private var iconColor: Color {
        let ext = item.fileName.split(separator: ".").last.map(String.init)?.lowercased() ?? ""
        switch ext {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "svg":
            return .pink
        case "mp4", "mov", "avi", "mkv", "webm":
            return .purple
        case "pdf":
            return .red
        case "zip", "rar", "7z", "tar", "gz":
            return .orange
        case "mp3", "wav", "aac", "flac", "m4a":
            return .cyan
        case "doc", "docx", "txt", "rtf", "md":
            return .blue
        case "xls", "xlsx", "csv":
            return .green
        default:
            return .accentColor
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            // File type badge
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(iconColor.opacity(0.1))
                    .frame(width: 44, height: 44)
                Text(fileExtension.prefix(4))
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(iconColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.fileName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    Text(item.formattedFileSize)
                    Text("\u{00B7}")
                    Text(item.uploadDate.formatted(.relative(presentation: .named)))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            // Copy URL button
            Button {
                viewModel.copyToClipboard(item.publicURL.absoluteString)
                withAnimation(.spring(response: 0.3)) { showCopied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation { showCopied = false }
                }
            } label: {
                ZStack {
                    if showCopied {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.green)
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.accentColor)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                viewModel.deleteHistoryItem(item)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                viewModel.copyToClipboard(item.publicURL.absoluteString)
                withAnimation(.spring(response: 0.3)) { showCopied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation { showCopied = false }
                }
            } label: {
                Label("Copy URL", systemImage: "doc.on.doc")
            }
            .tint(.accentColor)
        }
    }
}
#endif
