import SwiftUI

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
        let uploading = viewModel.uploadTasks.filter { $0.status == .uploading || $0.status == .completed }
        guard !uploading.isEmpty else { return 0 }
        let sum = uploading.reduce(0.0) { acc, t in acc + (t.status == .completed ? 1.0 : t.progress) }
        return sum / Double(viewModel.uploadTasks.count)
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
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text(headerSubtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                // Expand/collapse
                Button {
                    withAnimation(.spring(response: 0.3)) { isExpanded.toggle() }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                // Dismiss when all done
                if allDone {
                    Button {
                        viewModel.removeCompletedAndFailed()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            // Expanded task list
            if isExpanded {
                Divider()
                    .padding(.horizontal, 8)

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
                .frame(maxHeight: 200)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .glassEffectIfAvailable(cornerRadius: 12)
        .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 6)
        .frame(width: 280)
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
        return "\(viewModel.uploadTasks.filter { $0.status == .pending }.count) pending"
    }
}

// MARK: - HUD Task Row

private struct HUDTaskRow: View {
    let task: FileUploadTask

    var body: some View {
        HStack(spacing: 10) {
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
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case .uploading:
                    ProgressView(value: task.progress)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                case .completed:
                    Text("Done")
                        .font(.caption2)
                        .foregroundStyle(.green)
                case .failed:
                    Text(task.errorMessage ?? "Failed")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Text(ByteCountFormatter.string(fromByteCount: task.fileSize, countStyle: .file))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var icon: String {
        switch task.status {
        case .pending:   return "clock"
        case .uploading: return "arrow.up.circle"
        case .completed: return "checkmark.circle.fill"
        case .failed:    return "xmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch task.status {
        case .pending:   return .secondary
        case .uploading: return .accentColor
        case .completed: return .green
        case .failed:    return .red
        }
    }
}
