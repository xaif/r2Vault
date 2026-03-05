import SwiftUI

#if os(macOS)
private extension View {
    @ViewBuilder
    func glassEffectIfAvailable(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self
        }
    }
}
#endif

/// Non-blocking floating upload progress panel shown in the bottom-right corner.
/// Only visible when there are active, pending, or recently-completed uploads.
struct UploadHUDView: View {
    @Environment(AppViewModel.self) private var viewModel
    @State private var isExpanded = true

    private var activeTasks: [FileUploadTask] {
        viewModel.uploadTasks.filter {
            $0.status == .uploading || $0.status == .pending || $0.status == .failed
        }
    }

    private var completedCount: Int {
        viewModel.uploadTasks.filter { $0.status == .completed }.count
    }

    private var totalActive: Int { viewModel.uploadTasks.count }

    /// Combined progress across all uploading tasks
    private var overallProgress: Double {
        let trackable = viewModel.uploadTasks.filter {
            $0.status == .uploading || $0.status == .completed || $0.status == .failed || $0.status == .cancelled
        }
        guard !trackable.isEmpty else { return 0 }
        let sum = trackable.reduce(0.0) { acc, t in
            acc + (t.status == .completed ? 1.0 : t.progress)
        }
        return sum / Double(trackable.count)
    }

    var body: some View {
        if viewModel.uploadTasks.isEmpty { EmptyView() }
        else { hudPanel }
    }

    private var hudPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 8) {
                // Animated upload icon
                ZStack {
                    if activeTasks.contains(where: { $0.status == .uploading }) {
                        Circle()
                            .stroke(Color.accentColor.opacity(0.2), lineWidth: 2)
                            .frame(width: 22, height: 22)
                        Circle()
                            .trim(from: 0, to: overallProgress)
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .frame(width: 22, height: 22)
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.3), value: overallProgress)
                    } else {
                        Image(systemName: allDone ? "checkmark.circle.fill" : "arrow.up.circle.fill")
                            .foregroundStyle(allDone ? .green : Color.accentColor)
                            .font(.system(size: 18))
                    }
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(headerTitle)
                        .font(headerTitleFont)
                        .fontWeight(.semibold)
                    Text(headerSubtitle)
                        .font(headerSubtitleFont)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                // Expand/collapse
                Button {
                    withAnimation(.spring(response: 0.3)) { isExpanded.toggle() }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                // Dismiss when all done
                if allDone {
                    Button {
                        viewModel.removeCompletedAndFailed()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)

#if os(iOS)
            // Global progress bar for quick scan (Google Drive style)
            ProgressView(value: overallProgress)
                .progressViewStyle(.linear)
                .tint(.accentColor)
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, 10)
#endif

            // Expanded task list
            if isExpanded {
                Divider()
                    .padding(.horizontal, horizontalPadding - 4)

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(viewModel.uploadTasks) { task in
                            HUDTaskRow(task: task)
                            if task.id != viewModel.uploadTasks.last?.id {
                                Divider().padding(.horizontal, 12)
                            }
                        }
                    }
                }
                .frame(maxHeight: taskListMaxHeight)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
#if os(macOS)
        .glassEffectIfAvailable(cornerRadius: cornerRadius)
#endif
        .shadow(color: .black.opacity(0.12), radius: shadowRadius, x: 0, y: shadowYOffset)
#if os(iOS)
        .frame(maxWidth: .infinity)
#else
        .frame(width: 280)
#endif
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.spring(response: 0.4), value: viewModel.uploadTasks.count)
    }

    private var allDone: Bool {
        !viewModel.uploadTasks.isEmpty &&
        viewModel.uploadTasks.allSatisfy { $0.status == .completed || $0.status == .failed }
    }

    private var headerTitle: String {
        if allDone {
            return "Upload complete"
        }
        let uploading = viewModel.uploadTasks.filter { $0.status == .uploading }.count
        if uploading > 0 {
            return "Uploading \(completedCount + 1) of \(totalActive)…"
        }
        return "Preparing uploads…"
    }

    private var headerSubtitle: String {
        if allDone {
            let failed = viewModel.uploadTasks.filter { $0.status == .failed }.count
            return failed > 0 ? "\(completedCount) done, \(failed) failed" : "\(completedCount) file\(completedCount == 1 ? "" : "s") uploaded"
        }
        let pending = viewModel.uploadTasks.filter { $0.status == .pending }.count
        return "\(Int(overallProgress * 100))% complete • \(pending) pending"
    }

    private var cornerRadius: CGFloat {
#if os(iOS)
        return 18
#else
        return 12
#endif
    }

    private var horizontalPadding: CGFloat {
#if os(iOS)
        return 14
#else
        return 12
#endif
    }

    private var verticalPadding: CGFloat {
#if os(iOS)
        return 12
#else
        return 10
#endif
    }

    private var taskListMaxHeight: CGFloat {
#if os(iOS)
        return 240
#else
        return 200
#endif
    }

    private var headerTitleFont: Font {
#if os(iOS)
        return .subheadline
#else
        return .caption
#endif
    }

    private var headerSubtitleFont: Font {
#if os(iOS)
        return .caption
#else
        return .caption2
#endif
    }

    private var shadowRadius: CGFloat {
#if os(iOS)
        return 18
#else
        return 12
#endif
    }

    private var shadowYOffset: CGFloat {
#if os(iOS)
        return 10
#else
        return 6
#endif
    }
}

// MARK: - HUD Task Row

private struct HUDTaskRow: View {
    let task: FileUploadTask

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .font(.system(size: 13))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(task.fileName)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)

                switch task.status {
                case .pending:
                    Text("Waiting…")
                        .font(statusFont)
                        .foregroundStyle(.secondary)
                case .uploading:
                    ProgressView(value: task.progress)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                case .completed:
                    Text("Done")
                        .font(statusFont)
                        .foregroundStyle(.green)
                case .failed:
                    Text(task.errorMessage ?? "Failed")
                        .font(statusFont)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                case .cancelled:
                    Text("Cancelled")
                        .font(statusFont)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if task.status == .uploading {
                Text("\(Int(task.progress * 100))%")
                    .font(statusFont)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 34, alignment: .trailing)
                Button {
                    task.cancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 14))
                }
                .buttonStyle(.borderless)
                .help("Cancel upload")
            } else if task.status == .pending {
                Button {
                    task.cancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 14))
                }
                .buttonStyle(.borderless)
                .help("Cancel upload")
            } else {
                Text(ByteCountFormatter.string(fromByteCount: task.fileSize, countStyle: .file))
                    .font(statusFont)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, rowHorizontalPadding)
        .padding(.vertical, rowVerticalPadding)
    }

    private var icon: String {
        switch task.status {
        case .pending:   return "clock"
        case .uploading: return "arrow.up.circle"
        case .completed: return "checkmark.circle.fill"
        case .failed:    return "xmark.circle.fill"
        case .cancelled: return "slash.circle"
        }
    }

    private var iconColor: Color {
        switch task.status {
        case .pending:   return .secondary
        case .uploading: return .accentColor
        case .completed: return .green
        case .failed:    return .red
        case .cancelled: return .secondary
        }
    }

    private var statusFont: Font {
#if os(iOS)
        return .caption
#else
        return .caption2
#endif
    }

    private var rowHorizontalPadding: CGFloat {
#if os(iOS)
        return 14
#else
        return 12
#endif
    }

    private var rowVerticalPadding: CGFloat {
#if os(iOS)
        return 9
#else
        return 7
#endif
    }
}
