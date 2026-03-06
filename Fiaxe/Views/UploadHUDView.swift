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
#if os(iOS)
            // iOS: Modern header with pill-shaped progress ring
            HStack(spacing: 12) {
                // Animated circular progress indicator
                ZStack {
                    if activeTasks.contains(where: { $0.status == .uploading }) {
                        Circle()
                            .stroke(Color.accentColor.opacity(0.15), lineWidth: 3)
                            .frame(width: 36, height: 36)
                        Circle()
                            .trim(from: 0, to: overallProgress)
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .frame(width: 36, height: 36)
                            .rotationEffect(.degrees(-90))
                            .animation(.easeInOut(duration: 0.4), value: overallProgress)
                        Text("\(Int(overallProgress * 100))")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.accentColor)
                    } else {
                        Circle()
                            .fill(allDone ? Color.green.opacity(0.12) : Color.accentColor.opacity(0.12))
                            .frame(width: 36, height: 36)
                        Image(systemName: allDone ? "checkmark" : "arrow.up")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(allDone ? .green : Color.accentColor)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(headerTitle)
                        .font(.subheadline.weight(.semibold))
                    Text(headerSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                // Expand/collapse chevron
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { isExpanded.toggle() }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down.circle.fill" : "chevron.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.tertiary)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)

                // Dismiss when all done
                if allDone {
                    Button {
                        withAnimation(.spring(response: 0.3)) {
                            viewModel.removeCompletedAndFailed()
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.tertiary)
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            // Slim progress track
            if activeTasks.contains(where: { $0.status == .uploading }) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.accentColor.opacity(0.1))
                            .frame(height: 3)
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: geo.size.width * overallProgress, height: 3)
                            .animation(.easeInOut(duration: 0.3), value: overallProgress)
                    }
                }
                .frame(height: 3)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
#else
            HStack(spacing: 12) {
                ZStack {
                    if activeTasks.contains(where: { $0.status == .uploading }) {
                        Circle()
                            .stroke(Color.accentColor.opacity(0.15), lineWidth: 3)
                            .frame(width: 34, height: 34)
                        Circle()
                            .trim(from: 0, to: overallProgress)
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .frame(width: 34, height: 34)
                            .rotationEffect(.degrees(-90))
                            .animation(.easeInOut(duration: 0.35), value: overallProgress)
                        Text("\(Int(overallProgress * 100))")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.accentColor)
                    } else {
                        Circle()
                            .fill(allDone ? Color.green.opacity(0.12) : Color.accentColor.opacity(0.12))
                            .frame(width: 34, height: 34)
                        Image(systemName: allDone ? "checkmark" : "arrow.up")
                            .foregroundStyle(allDone ? .green : Color.accentColor)
                            .font(.system(size: 14, weight: .semibold))
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(headerTitle)
                        .font(.system(size: 13, weight: .semibold))
                    Text(headerSubtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { isExpanded.toggle() }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down.circle.fill" : "chevron.up.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.tertiary)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)

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
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, activeTasks.contains(where: { $0.status == .uploading }) ? 8 : 14)

            if activeTasks.contains(where: { $0.status == .uploading }) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.accentColor.opacity(0.1))
                            .frame(height: 4)
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: geo.size.width * overallProgress, height: 4)
                            .animation(.easeInOut(duration: 0.3), value: overallProgress)
                    }
                }
                .frame(height: 4)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
#endif

            // Expanded task list
            if isExpanded {
#if os(iOS)
                Divider()
                    .padding(.horizontal, 12)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.uploadTasks) { task in
                            IOSHUDTaskRow(task: task)
                            if task.id != viewModel.uploadTasks.last?.id {
                                Divider()
                                    .padding(.leading, 56)
                                    .padding(.trailing, 16)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 260)
#else
                Divider()
                    .padding(.horizontal, 12)

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(viewModel.uploadTasks) { task in
                            HUDTaskRow(task: task)
                            if task.id != viewModel.uploadTasks.last?.id {
                                Divider().padding(.leading, 58).padding(.trailing, 16)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 240)
#endif
            }
        }
        .background(hudBackground)
#if os(macOS)
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(hudBorder, lineWidth: 1)
        }
#endif
#if os(macOS)
        .glassEffectIfAvailable(cornerRadius: cornerRadius)
#endif
        .shadow(color: .black.opacity(0.12), radius: shadowRadius, x: 0, y: shadowYOffset)
#if os(iOS)
        .frame(maxWidth: .infinity)
#else
        .frame(width: 328)
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
            return "Uploading \(completedCount + 1) of \(totalActive)..."
        }
        return "Preparing uploads..."
    }

    private var headerSubtitle: String {
        if allDone {
            let failed = viewModel.uploadTasks.filter { $0.status == .failed }.count
            return failed > 0 ? "\(completedCount) done, \(failed) failed" : "\(completedCount) file\(completedCount == 1 ? "" : "s") uploaded"
        }
        let pending = viewModel.uploadTasks.filter { $0.status == .pending }.count
        return "\(Int(overallProgress * 100))% complete \u{00B7} \(pending) pending"
    }

    private var cornerRadius: CGFloat {
#if os(iOS)
        return 20
#else
        return 18
#endif
    }

    private var shadowRadius: CGFloat {
#if os(iOS)
        return 20
#else
        return 24
#endif
    }

    private var shadowYOffset: CGFloat {
#if os(iOS)
        return 8
#else
        return 14
#endif
    }

    @ViewBuilder
    private var hudBackground: some View {
#if os(iOS)
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(.regularMaterial)
#else
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(.ultraThinMaterial)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.82),
                                Color.accentColor.opacity(0.08),
                                Color.white.opacity(0.72)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.5),
                                Color.white.opacity(0.08),
                                .clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .padding(1)
                    .blendMode(.screen)
            }
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(Color.accentColor.opacity(0.1))
                    .frame(width: 140, height: 140)
                    .blur(radius: 28)
                    .offset(x: 36, y: 42)
                    .allowsHitTesting(false)
            }
#endif
    }

    private var hudBorder: Color {
        Color.white.opacity(0.5)
    }
}

// MARK: - iOS HUD Task Row (modern design)

#if os(iOS)
private struct IOSHUDTaskRow: View {
    let task: FileUploadTask

    private let ringSize: CGFloat = 34
    private let ringLineWidth: CGFloat = 3

    var body: some View {
        HStack(spacing: 14) {
            // Trailing circular progress ring (leading position for visual weight)
            ZStack {
                Circle()
                    .stroke(ringTrackColor, lineWidth: ringLineWidth)
                Circle()
                    .trim(from: 0, to: ringProgress)
                    .stroke(ringFillColor, style: StrokeStyle(lineWidth: ringLineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                // Center content — always same frame to avoid shift
                Group {
                    switch task.status {
                    case .completed:
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.green)
                    case .failed:
                        Image(systemName: "exclamationmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.red)
                    case .uploading:
                        Text("\(Int(task.progress * 100))")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.accentColor)
                    case .pending:
                        Image(systemName: "ellipsis")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    case .cancelled:
                        Image(systemName: "minus")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
                .transition(.blurReplace)
            }
            .frame(width: ringSize, height: ringSize)
            .animation(.easeInOut(duration: 0.4), value: ringProgress)
            .animation(.easeInOut(duration: 0.3), value: task.status)

            // File info — fixed height subtitle area to prevent layout shift
            VStack(alignment: .leading, spacing: 2) {
                Text(task.fileName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                // Subtitle — always occupies the same height
                subtitleView
                    .frame(height: 16, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Trailing area — fixed width so nothing shifts when cancel hides
            trailingView
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .animation(.easeInOut(duration: 0.25), value: task.status)
    }

    // MARK: - Subtitle

    @ViewBuilder
    private var subtitleView: some View {
        switch task.status {
        case .pending:
            Text("Waiting...")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .uploading:
            HStack(spacing: 6) {
                Capsule()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(height: 4)
                    .overlay(alignment: .leading) {
                        GeometryReader { geo in
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(width: geo.size.width * max(task.progress, 0.02), height: 4)
                                .animation(.easeInOut(duration: 0.25), value: task.progress)
                        }
                    }
                Text("\(Int(task.progress * 100))%")
                    .font(.system(.caption2, design: .rounded, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .trailing)
            }
        case .completed:
            Text(ByteCountFormatter.string(fromByteCount: task.fileSize, countStyle: .file))
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed:
            Text(task.errorMessage ?? "Failed")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)
        case .cancelled:
            Text("Cancelled")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Trailing

    @ViewBuilder
    private var trailingView: some View {
        if task.status == .uploading || task.status == .pending {
            Button {
                task.cancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color(.tertiaryLabel))
            }
            .buttonStyle(.plain)
            .transition(.opacity)
        } else if task.status == .completed {
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.green)
                .transition(.scale.combined(with: .opacity))
        } else {
            Color.clear
        }
    }

    // MARK: - Ring

    private var ringProgress: Double {
        switch task.status {
        case .pending:   return 0
        case .uploading: return task.progress
        case .completed: return 1.0
        case .failed:    return 1.0
        case .cancelled: return 0
        }
    }

    private var ringTrackColor: Color {
        switch task.status {
        case .completed: return .green.opacity(0.15)
        case .failed:    return .red.opacity(0.15)
        case .uploading: return Color.accentColor.opacity(0.12)
        default:         return Color(.tertiarySystemFill)
        }
    }

    private var ringFillColor: Color {
        switch task.status {
        case .completed: return .green
        case .failed:    return .red
        case .uploading: return .accentColor
        default:         return .secondary.opacity(0.3)
        }
    }
}
#endif

// MARK: - macOS HUD Task Row

#if os(macOS)
private struct HUDTaskRow: View {
    let task: FileUploadTask

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(ringTrackColor, lineWidth: 3)
                Circle()
                    .trim(from: 0, to: ringProgress)
                    .stroke(ringFillColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                Group {
                    switch task.status {
                    case .completed:
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.green)
                    case .failed:
                        Image(systemName: "exclamationmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.red)
                    case .uploading:
                        Text("\(Int(task.progress * 100))")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.accentColor)
                    case .pending:
                        Image(systemName: "ellipsis")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    case .cancelled:
                        Image(systemName: "minus")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.fileName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                subtitleView
                    .frame(height: 16, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if task.status == .uploading || task.status == .pending {
                Button {
                    task.cancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)
                .help("Cancel upload")
            } else {
                trailingMetaView
                    .frame(width: 34, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var subtitleView: some View {
        switch task.status {
        case .pending:
            Text("Waiting...")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .uploading:
            HStack(spacing: 6) {
                Capsule()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(height: 4)
                    .overlay(alignment: .leading) {
                        GeometryReader { geo in
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(width: geo.size.width * max(task.progress, 0.02), height: 4)
                        }
                    }
                Text("\(Int(task.progress * 100))%")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .trailing)
            }
        case .completed:
            Text("Uploaded")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed:
            Text(task.errorMessage ?? "Failed")
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
    private var trailingMetaView: some View {
        if task.status == .completed {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.green)
        } else if task.status == .failed {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.red)
        } else {
            Text(ByteCountFormatter.string(fromByteCount: task.fileSize, countStyle: .file))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var ringProgress: Double {
        switch task.status {
        case .pending:   return 0
        case .uploading: return task.progress
        case .completed: return 1.0
        case .failed:    return 1.0
        case .cancelled: return 0
        }
    }

    private var ringTrackColor: Color {
        switch task.status {
        case .completed: return .green.opacity(0.15)
        case .failed:    return .red.opacity(0.15)
        case .uploading: return Color.accentColor.opacity(0.12)
        default:         return .secondary.opacity(0.16)
        }
    }

    private var ringFillColor: Color {
        switch task.status {
        case .completed: return .green
        case .failed:    return .red
        case .uploading: return .accentColor
        default:         return .secondary.opacity(0.3)
        }
    }
}
#endif
