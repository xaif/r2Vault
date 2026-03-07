#if os(iOS)
import ActivityKit
import SwiftUI
import WidgetKit

private extension Color {
    static let accent = Color(red: 248 / 255, green: 105 / 255, blue: 54 / 255)
    static let surface = Color(red: 20 / 255, green: 20 / 255, blue: 24 / 255)
    static let elevatedSurface = Color.white.opacity(0.08)
    static let track = Color.white.opacity(0.14)
    static let ink = Color.white.opacity(0.96)
    static let mutedInk = Color.white.opacity(0.62)
}

private struct FlightStyleProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geometry in
            let clampedProgress = min(max(progress, 0), 1)
            let width = geometry.size.width
            let indicatorOffset = max(min(width * clampedProgress, width - 18), 18)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.track)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.accent, Color.accent.opacity(0.82)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(width * clampedProgress, 28))

                Circle()
                    .fill(Color.surface)
                    .frame(width: 18, height: 18)
                    .overlay {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.accent)
                    }
                    .offset(x: indicatorOffset - 9)
                    .shadow(color: Color.accent.opacity(0.18), radius: 8, y: 2)

                Circle()
                    .fill(Color.white.opacity(0.14))
                    .frame(width: 18, height: 18)
                    .overlay {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(clampedProgress >= 1 ? Color.accent : Color.mutedInk)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(height: 18)
    }
}

private struct MetricBlock: View {
    let value: String
    let label: String
    let alignment: HorizontalAlignment
    let valueColor: Color

    var body: some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(valueColor)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Color.mutedInk)
        }
    }
}

struct UploadLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: UploadActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(Color.surface)
                .activitySystemActionForegroundColor(Color.ink)
        } dynamicIsland: { context in
#if os(iOS)
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ExpandedMetricColumn(state: context.state)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    ExpandedProgressColumn(state: context.state)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        FlightStyleProgressBar(progress: context.state.progress)

                        HStack(spacing: 10) {
                            DetailPill(icon: "clock", text: "\(context.state.pendingCount) pending")

                            Text(context.state.currentFileName)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.mutedInk)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .padding(.bottom, 6)
                }
            } compactLeading: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundStyle(Color.accent)
                    Text("\(context.state.completedCount)/\(max(context.state.totalCount, 1))")
                        .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.ink)
                }
            } compactTrailing: {
                Text("\(Int(context.state.progress * 100))%")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.accent)
                    .contentTransition(.numericText())
            } minimal: {
                ZStack {
                    Circle()
                        .fill(Color.surface)
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundStyle(Color.accent)
                }
            }
#else
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    LockScreenView(state: context.state)
                }
            } compactLeading: {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundStyle(Color.accent)
            } compactTrailing: {
                Text("\(Int(context.state.progress * 100))%")
                    .foregroundStyle(Color.accent)
            } minimal: {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundStyle(Color.accent)
            }
#endif
        }
    }
}

private struct LockScreenView: View {
    let state: UploadActivityAttributes.ContentState

    private var progressPercent: Int {
        Int(state.progress * 100)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.surface, Color.surface.opacity(0.92)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )

            Circle()
                .fill(Color.accent.opacity(0.18))
                .frame(width: 140, height: 140)
                .blur(radius: 30)
                .offset(x: 120, y: -50)

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.accent)

                        Text("R2 Vault")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.mutedInk)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(state.statusText)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }

                HStack(alignment: .top, spacing: 20) {
                    MetricBlock(
                        value: "\(state.completedCount)/\(max(state.totalCount, 1))",
                        label: "Uploaded",
                        alignment: .leading,
                        valueColor: Color.ink
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)

                    MetricBlock(
                        value: "\(progressPercent)%",
                        label: "Complete",
                        alignment: .trailing,
                        valueColor: Color.accent
                    )
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }

                FlightStyleProgressBar(progress: state.progress)

                HStack(spacing: 12) {
                    DetailPill(icon: "clock", text: "\(state.pendingCount) pending")
                    Text(state.currentFileName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.mutedInk)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(state.totalCount == 0 ? "Done" : "Active")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accent)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }
}

private struct ExpandedMetricColumn: View {
    let state: UploadActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("R2 Vault")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.mutedInk)
                .lineLimit(1)

            Text("\(state.completedCount)/\(max(state.totalCount, 1))")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.ink)

            Text("UPLOADED")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(Color.mutedInk)
        }
    }
}

private struct ExpandedProgressColumn: View {
    let state: UploadActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text(state.statusText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text("\(Int(state.progress * 100))%")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.accent)
                .contentTransition(.numericText())

            Text("COMPLETE")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(Color.mutedInk)
        }
    }
}

private struct DetailPill: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(Color.ink)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.elevatedSurface)
        )
    }
}
#endif
