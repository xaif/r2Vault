import SwiftUI

struct HistoryRowView: View {
    let item: UploadItem
    @Environment(AppViewModel.self) private var viewModel
    @State private var showDeleteConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.fileName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Text(item.formattedFileSize)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    viewModel.downloadHistoryItem(item)
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.borderless)
                .help("Download")

                Button {
                    viewModel.copyToClipboard(item.publicURL.absoluteString)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy URL")

                Menu {
                    Button {
                        viewModel.removeHistoryItem(item)
                    } label: {
                        Label("Remove from History", systemImage: "clock.badge.xmark")
                    }

                    Divider()

                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete from R2", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
#if os(macOS)
                .menuStyle(.borderlessButton)
#endif
            }

            Text(item.publicURL.absoluteString)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(item.uploadDate.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .confirmationDialog(
            "Delete \"\(item.fileName)\" from R2?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete from R2", role: .destructive) {
                viewModel.deleteHistoryItem(item)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the object from your bucket and also removes the history entry.")
        }
    }
}
