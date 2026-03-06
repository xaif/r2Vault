import SwiftUI

struct UploadRowView: View {
    let task: FileUploadTask
    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
#if os(iOS)
        iOSRow
#else
        macOSRow
#endif
    }

    // MARK: - iOS

#if os(iOS)
    private var iOSRow: some View {
        HStack(spacing: 12) {
            // Status icon with colored background
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(statusColor.opacity(0.1))
                    .frame(width: 44, height: 44)
                Image(systemName: statusIcon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(statusColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(task.fileName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Text(ByteCountFormatter.string(fromByteCount: task.fileSize, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                switch task.status {
                case .pending:
                    Text("Waiting...")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                case .uploading:
                    HStack(spacing: 8) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.accentColor.opacity(0.12))
                                    .frame(height: 4)
                                Capsule()
                                    .fill(Color.accentColor)
                                    .frame(width: geo.size.width * task.progress, height: 4)
                                    .animation(.easeInOut(duration: 0.25), value: task.progress)
                            }
                        }
                        .frame(height: 4)

                        Text("\(Int(task.progress * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }

                case .completed:
                    if let url = task.resultURL {
                        Text(url.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                case .failed:
                    Text(task.errorMessage ?? "Upload failed")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)

                case .cancelled:
                    Text("Cancelled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Trailing actions
            if task.status == .completed, let url = task.resultURL {
                Button {
                    viewModel.copyToClipboard(url.absoluteString)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }

            if task.status == .pending || task.status == .uploading {
                Button {
                    task.cancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.tertiary)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
    }
#endif

    // MARK: - macOS

#if os(macOS)
    private var macOSRow: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(statusColor.opacity(0.1))
                    .frame(width: 46, height: 46)

                if task.status == .uploading {
                    Circle()
                        .stroke(Color.accentColor.opacity(0.15), lineWidth: 3)
                        .frame(width: 28, height: 28)
                    Circle()
                        .trim(from: 0, to: max(task.progress, 0.02))
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 28, height: 28)
                        .rotationEffect(.degrees(-90))
                    Text("\(Int(task.progress * 100))")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.accentColor)
                } else {
                    Image(systemName: statusIcon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(statusColor)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(task.fileName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 8)

                    Text(ByteCountFormatter.string(fromByteCount: task.fileSize, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                macOSSubtitleView
                    .frame(height: 18, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            macOSTrailingView
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(statusCardFill)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(statusCardBorder, lineWidth: 1)
        }
        .animation(.easeInOut(duration: 0.25), value: task.status)
        .animation(.easeInOut(duration: 0.25), value: task.progress)
    }

    @ViewBuilder
    private var macOSSubtitleView: some View {
        switch task.status {
        case .pending:
            Text("Waiting...")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .uploading:
            HStack(spacing: 8) {
                Capsule()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(height: 5)
                    .overlay(alignment: .leading) {
                        GeometryReader { geo in
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(width: geo.size.width * max(task.progress, 0.02), height: 5)
                        }
                    }

                Text("\(Int(task.progress * 100))%")
                    .font(.system(.caption2, design: .rounded, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }

        case .completed:
            if let url = task.resultURL {
                Text(url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Uploaded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .failed:
            Text(task.errorMessage ?? "Upload failed")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)

        case .cancelled:
            Text("Cancelled")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var macOSTrailingView: some View {
        if task.status == .completed, let url = task.resultURL {
            Button {
                viewModel.copyToClipboard(url.absoluteString)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("Copy URL to clipboard")
        } else if task.status == .pending || task.status == .uploading {
            Button {
                task.cancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.tertiary)
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .help("Cancel upload")
        } else if task.status == .failed {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.red)
        } else {
            Color.clear
        }
    }
#endif

    private var statusIcon: String {
        switch task.status {
        case .pending:   "clock"
        case .uploading: "arrow.up.circle"
        case .completed: "checkmark.circle.fill"
        case .failed:    "xmark.circle.fill"
        case .cancelled: "slash.circle"
        }
    }

    private var statusColor: Color {
        switch task.status {
        case .pending:   .secondary
        case .uploading: .accentColor
        case .completed: .green
        case .failed:    .red
        case .cancelled: .secondary
        }
    }

    private var statusCardFill: Color {
        switch task.status {
        case .completed:
            return .green.opacity(0.06)
        case .failed:
            return .red.opacity(0.06)
        case .uploading:
            return Color.accentColor.opacity(0.05)
        default:
            return Color.secondary.opacity(0.05)
        }
    }

    private var statusCardBorder: Color {
        switch task.status {
        case .completed:
            return .green.opacity(0.12)
        case .failed:
            return .red.opacity(0.14)
        case .uploading:
            return Color.accentColor.opacity(0.12)
        default:
            return Color.secondary.opacity(0.08)
        }
    }
}
