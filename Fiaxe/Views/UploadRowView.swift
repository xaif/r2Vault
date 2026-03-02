import SwiftUI

struct UploadRowView: View {
    let task: FileUploadTask
    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                    .frame(width: 16)

                Text(task.fileName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Text(ByteCountFormatter.string(fromByteCount: task.fileSize, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if task.status == .completed, let url = task.resultURL {
                    Button {
                        viewModel.copyToClipboard(url.absoluteString)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy URL to clipboard")
                }
            }

            switch task.status {
            case .pending:
                Text("Waiting…")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .uploading:
                VStack(alignment: .leading, spacing: 2) {
                    ProgressView(value: task.progress)
                    Text("\(Int(task.progress * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

            case .completed:
                if let url = task.resultURL {
                    Text(url.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

            case .failed:
                Text(task.errorMessage ?? "Upload failed")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusIcon: String {
        switch task.status {
        case .pending:   "clock"
        case .uploading: "arrow.up.circle"
        case .completed: "checkmark.circle.fill"
        case .failed:    "xmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch task.status {
        case .pending:   .secondary
        case .uploading: .blue
        case .completed: .green
        case .failed:    .red
        }
    }
}
