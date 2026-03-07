import SwiftUI

struct DashboardView: View {
    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        Group {
            if viewModel.credentialsList.isEmpty {
                noBucketsView
            } else if viewModel.isScanning && viewModel.bucketStats == nil {
                scanningView
            } else if let stats = viewModel.bucketStats {
                dashboardContent(stats)
            } else if let error = viewModel.scanError {
                errorView(error)
            } else {
                // Not yet scanned
                notScannedView
            }
        }
        .onAppear {
            if viewModel.bucketStats == nil && !viewModel.isScanning && viewModel.hasCredentials {
                viewModel.scanBucket()
            }
        }
    }

    // MARK: - States

    private var noBucketsView: some View {
        ContentUnavailableView {
            Label("No Buckets", systemImage: "chart.bar.xaxis.ascending")
        } description: {
            Text("Add your Cloudflare R2 credentials in Settings to view dashboard.")
        }
    }

    private var scanningView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Scanning bucket...")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var notScannedView: some View {
        ContentUnavailableView {
            Label("Dashboard", systemImage: "chart.bar.xaxis.ascending")
        } description: {
            Text("Scan your bucket to view storage analytics.")
        } actions: {
            Button("Scan Bucket") {
                viewModel.scanBucket()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func errorView(_ error: String) -> some View {
        ContentUnavailableView {
            Label("Scan Failed", systemImage: "exclamationmark.triangle")
        } description: {
            Text(error)
        } actions: {
            Button("Retry") {
                viewModel.scanBucket()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Dashboard Content

    private func dashboardContent(_ stats: BucketStats) -> some View {
        GeometryReader { proxy in
            let contentWidth = min(max(proxy.size.width - 32, 0), 1400)
            let usesTwoColumns = contentWidth >= 980

            ScrollView {
                VStack(spacing: 20) {
                    headerBar(stats)
                    overviewSection(stats, availableWidth: contentWidth)
                    fileTypesSection(stats, availableWidth: contentWidth)

                    if usesTwoColumns {
                        HStack(alignment: .top, spacing: 16) {
                            largestFilesSection(stats)
                                .frame(maxWidth: .infinity, alignment: .top)
                            recentFilesSection(stats)
                                .frame(maxWidth: .infinity, alignment: .top)
                        }
                    } else {
                        largestFilesSection(stats)
                        recentFilesSection(stats)
                    }

                    uploadHistorySection(availableWidth: contentWidth)

                    Spacer(minLength: 20)
                }
                .frame(maxWidth: contentWidth)
                .padding()
                .frame(maxWidth: .infinity)
            }
            .background(dashboardBackground)
        }
    }

    // MARK: - Header

    private func headerBar(_ stats: BucketStats) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.credentials?.bucketName ?? "Bucket")
                    .font(.title2.bold())
                if let scanned = stats.lastScanned {
                    Text("Last scanned \(scanned.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                viewModel.scanBucket()
            } label: {
                HStack(spacing: 6) {
                    if viewModel.isScanning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(viewModel.isScanning ? "Scanning..." : "Refresh")
                }
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isScanning)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    // MARK: - Overview Cards

    private func overviewSection(_ stats: BucketStats, availableWidth: CGFloat) -> some View {
        let cards: [(String, String, String, Color)] = [
            ("Total Storage", stats.formattedTotalSize, "externaldrive.fill", .accentColor),
            ("Files", "\(stats.totalFiles)", "doc.fill", .blue),
            ("Folders", "\(stats.totalFolders)", "folder.fill", .accentColor),
            ("File Types", "\(stats.filesByType.filter { $0.value.count > 0 }.count)", "square.grid.2x2.fill", .purple),
        ]

        #if os(iOS)
        let columnCount = 2
        #else
        let columnCount = max(1, min(Int(availableWidth / 220), 4))
        #endif
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: columnCount)

        return LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                StatCard(title: card.0, value: card.1, icon: card.2, color: card.3)
            }
        }
    }

    // MARK: - File Types Breakdown

    private func fileTypesSection(_ stats: BucketStats, availableWidth: CGFloat) -> some View {
        DashboardSection(title: "Storage by File Type", icon: "chart.pie.fill") {
            let sorted = stats.filesByType
                .sorted { $0.value.totalSize > $1.value.totalSize }
                .filter { $0.value.count > 0 }

            if sorted.isEmpty {
                Text("No files found")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                VStack(spacing: 10) {
                    // Bar visualization
                    GeometryReader { geo in
                        HStack(spacing: 2) {
                            ForEach(sorted, id: \.key) { category, catStats in
                                let fraction = stats.totalSize > 0
                                    ? CGFloat(catStats.totalSize) / CGFloat(stats.totalSize)
                                    : 0
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(colorForCategory(category))
                                    .frame(width: max(fraction * geo.size.width, 4))
                            }
                        }
                    }
                    .frame(height: 12)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    // Legend
                    #if os(iOS)
                    let legendColumns: [GridItem] = availableWidth >= 520
                        ? [
                            GridItem(.flexible(), spacing: 12, alignment: .top),
                            GridItem(.flexible(), spacing: 12, alignment: .top),
                        ]
                        : [GridItem(.flexible(), spacing: 0, alignment: .top)]
                    #else
                    let minimumLegendWidth: CGFloat = availableWidth >= 1200 ? 220 : 250
                    let legendColumns: [GridItem] = [
                        GridItem(.adaptive(minimum: minimumLegendWidth, maximum: 320), spacing: 14, alignment: .top)
                    ]
                    #endif

                    LazyVGrid(columns: legendColumns, alignment: .leading, spacing: 12) {
                        ForEach(sorted, id: \.key) { category, catStats in
                            fileTypeRow(category: category, catStats: catStats, totalSize: stats.totalSize)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        #if os(iOS)
                                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                                        #else
                                        .fill(.white.opacity(0.6))
                                        #endif
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        #if os(iOS)
                                        .strokeBorder(.quaternary.opacity(0.4), lineWidth: 0.75)
                                        #else
                                        .strokeBorder(colorForCategory(category).opacity(0.08), lineWidth: 1)
                                        #endif
                                )
                        }
                    }
                }
            }
        }
    }

    private func fileTypeRow(category: BucketStats.FileCategory, catStats: BucketStats.CategoryStats, totalSize: Int64) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(colorForCategory(category))
                .frame(width: 8, height: 8)
            Image(systemName: category.icon)
                .font(.caption)
                .foregroundStyle(colorForCategory(category))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(category.rawValue)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text("\(catStats.count) files")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(catStats.formattedSize)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(minWidth: 70, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Largest Files

    private func largestFilesSection(_ stats: BucketStats) -> some View {
        DashboardSection(title: "Largest Files", icon: "arrow.up.right.circle.fill") {
            if stats.largestFiles.isEmpty {
                Text("No files")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(stats.largestFiles.prefix(10).enumerated()), id: \.element.id) { index, file in
                        HStack(spacing: 10) {
                            Text("\(index + 1)")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            Image(systemName: iconForFile(file.name))
                                .font(.system(size: 13))
                                .foregroundStyle(iconColorForFile(file.name))
                                .frame(width: 18)
                            Text(file.name)
                                .font(.callout)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(file.formattedSize)
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 4)
                        if index < min(stats.largestFiles.count, 10) - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Recent Files (Timeline Style)

    private func recentFilesSection(_ stats: BucketStats) -> some View {
        DashboardSection(title: "Latest in Bucket", icon: "sparkles") {
            if stats.recentFiles.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(.title2)
                            .foregroundStyle(.quaternary)
                        Text("No files yet")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 12)
                    Spacer()
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(stats.recentFiles.prefix(5).enumerated()), id: \.element.id) { index, file in
                        HStack(spacing: 10) {
                            recentFileTimelineMarker(color: iconColorForFile(file.name))
                                .frame(width: 18)

                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(iconColorForFile(file.name).opacity(0.12))
                                    .frame(width: 28, height: 28)
                                Image(systemName: iconForFile(file.name))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(iconColorForFile(file.name))
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                Text(file.formattedSize)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Text(file.lastModified?.formatted(.relative(presentation: .named)) ?? "Unknown")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 4)
                        if index < min(stats.recentFiles.count, 5) - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Upload Insights

    private func uploadHistorySection(availableWidth: CGFloat) -> some View {
        let items = currentBucketUploadItems
        let totalUploaded = items.reduce(into: Int64(0)) { $0 += $1.fileSize }
        let today = items.filter { Calendar.current.isDateInToday($0.uploadDate) }
        let last7Days = items.filter { $0.uploadDate > Date().addingTimeInterval(-7 * 24 * 3600) }

        // Build a 7-day sparkline of upload counts
        let cal = Calendar.current
        let dayBuckets: [Int] = (0..<7).reversed().map { daysAgo in
            let dayStart = cal.startOfDay(for: Date().addingTimeInterval(-Double(daysAgo) * 86400))
            let dayEnd = dayStart.addingTimeInterval(86400)
            return items.filter { $0.uploadDate >= dayStart && $0.uploadDate < dayEnd }.count
        }
        let maxCount = dayBuckets.max() ?? 1
        let summaryColumns = availableWidth >= 860
            ? [
                GridItem(.flexible(), spacing: 12, alignment: .topLeading),
                GridItem(.flexible(), spacing: 12, alignment: .topLeading),
                GridItem(.flexible(), spacing: 12, alignment: .topLeading),
            ]
            : [
                GridItem(.flexible(), spacing: 12, alignment: .topLeading),
                GridItem(.flexible(), spacing: 12, alignment: .topLeading),
            ]

        return DashboardSection(title: "Upload Insights", icon: "arrow.up.doc.fill") {
            VStack(spacing: 16) {
                LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 12) {
                    insightSummaryCard(
                        icon: "calendar",
                        title: "Today",
                        value: "\(today.count)",
                        detail: today.count == 1 ? "file" : "files"
                    )
                    insightSummaryCard(
                        icon: "chart.line.uptrend.xyaxis",
                        title: "This Week",
                        value: "\(last7Days.count)",
                        detail: ByteCountFormatter.string(
                            fromByteCount: last7Days.reduce(0) { $0 + $1.fileSize },
                            countStyle: .file
                        )
                    )
                    insightSummaryCard(
                        icon: "infinity",
                        title: "All Time",
                        value: "\(items.count)",
                        detail: ByteCountFormatter.string(fromByteCount: totalUploaded, countStyle: .file)
                    )
                }

                // 7-day bar chart
                VStack(alignment: .leading, spacing: 6) {
                    Text("Last 7 Days")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)

                    HStack(alignment: .bottom, spacing: 4) {
                        ForEach(Array(dayBuckets.enumerated()), id: \.offset) { index, count in
                            VStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(count > 0 ? Color.accentColor : Color.accentColor.opacity(0.15))
                                    .frame(height: max(CGFloat(count) / CGFloat(max(maxCount, 1)) * 40, 4))

                                Text(dayLabel(daysAgo: 6 - index))
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 56)
                }

                // Recent uploads list (last 3)
                if !items.isEmpty {
                    Divider()
                    VStack(spacing: 0) {
                        ForEach(Array(items.prefix(3).enumerated()), id: \.element.id) { index, item in
                            HStack(spacing: 10) {
                                ZStack {
                                    Circle()
                                        .fill(Color.accentColor.opacity(0.12))
                                        .frame(width: 30, height: 30)
                                    Image(systemName: "arrow.up")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(Color.accentColor)
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.fileName)
                                        .font(.callout.weight(.medium))
                                        .lineLimit(1)
                                    Text("\(item.formattedFileSize) · \(item.uploadDate.formatted(.relative(presentation: .named)))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Text(item.bucketName)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        Capsule().fill(.quaternary)
                                    )
                            }
                            .padding(.vertical, 5)
                            if index < min(items.count, 3) - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    private func dayLabel(daysAgo: Int) -> String {
        let date = Date().addingTimeInterval(-Double(daysAgo) * 86400)
        let fmt = DateFormatter()
        fmt.dateFormat = daysAgo == 0 ? "'Today'" : "EEE"
        return fmt.string(from: date)
    }

    private func insightSummaryCard(icon: String, title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 30, height: 30)
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }

                Spacer()
            }

            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(value)
                    .font(.title2.bold().monospacedDigit())

                Spacer(minLength: 4)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                #if os(iOS)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.quaternary.opacity(0.4), lineWidth: 0.75)
                )
                #else
                .fill(.white.opacity(0.82))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.03), radius: 8, x: 0, y: 4)
                #endif
        )
    }

    private func recentFileTimelineMarker(color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .frame(width: 8)
    }

    private var currentBucketUploadItems: [UploadItem] {
        guard let bucketName = viewModel.credentials?.bucketName, !bucketName.isEmpty else {
            return viewModel.historyStore.items
        }

        return viewModel.historyStore.items.filter { $0.bucketName == bucketName }
    }

    // MARK: - Helpers

    private func colorForCategory(_ category: BucketStats.FileCategory) -> Color {
        switch category {
        case .images: return .purple
        case .videos: return .pink
        case .audio: return .orange
        case .documents: return .blue
        case .archives: return .brown
        case .code: return .mint
        case .other: return .gray
        }
    }

    private var dashboardBackground: some View {
        #if os(iOS)
        Color(uiColor: .systemGroupedBackground)
            .ignoresSafeArea()
        #else
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.985, green: 0.978, blue: 0.968),
                    Color.white,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color.accentColor.opacity(0.08))
                .frame(width: 420, height: 420)
                .blur(radius: 60)
                .offset(x: 280, y: -180)

            Circle()
                .fill(Color.orange.opacity(0.08))
                .frame(width: 320, height: 320)
                .blur(radius: 50)
                .offset(x: -260, y: 260)
        }
        .ignoresSafeArea()
        #endif
    }

    private func iconForFile(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "svg":
            return "photo"
        case "mp4", "mov", "avi", "mkv", "webm", "m4v":
            return "film"
        case "mp3", "m4a", "wav", "aac", "flac", "ogg":
            return "music.note"
        case "pdf":
            return "doc.richtext"
        case "zip", "tar", "gz", "bz2", "7z", "rar":
            return "archivebox"
        default:
            return "doc"
        }
    }

    private func iconColorForFile(_ name: String) -> Color {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "svg":
            return .purple
        case "mp4", "mov", "avi", "mkv", "webm", "m4v":
            return .pink
        case "mp3", "m4a", "wav", "aac", "flac", "ogg":
            return .orange
        case "pdf":
            return .red
        case "zip", "tar", "gz", "bz2", "7z", "rar":
            return .brown
        default:
            return .secondary
        }
    }
}

// MARK: - Stat Card

private struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(color.opacity(0.12))
                        .frame(width: 34, height: 34)
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(color)
                }
                Spacer()
            }
            Text(value)
                .font(.title2.bold().monospacedDigit())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12)
                #if os(iOS)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                #else
                .fill(.white.opacity(0.82))
                #endif
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        #if os(iOS)
                        .strokeBorder(.quaternary.opacity(0.5), lineWidth: 0.75)
                        #else
                        .strokeBorder(color.opacity(0.12), lineWidth: 1)
                        #endif
                )
                #if os(macOS)
                .shadow(color: .black.opacity(0.04), radius: 10, x: 0, y: 6)
                #endif
        }
    }
}

// MARK: - Dashboard Section

private struct DashboardSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 12)
                #if os(iOS)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                #else
                .fill(.white.opacity(0.82))
                #endif
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        #if os(iOS)
                        .strokeBorder(.quaternary.opacity(0.4), lineWidth: 0.75)
                        #else
                        .strokeBorder(.black.opacity(0.04), lineWidth: 1)
                        #endif
                )
                #if os(macOS)
                .shadow(color: .black.opacity(0.045), radius: 14, x: 0, y: 8)
                #endif
        }
    }
}

#Preview {
    DashboardView()
        .environment(AppViewModel())
}
