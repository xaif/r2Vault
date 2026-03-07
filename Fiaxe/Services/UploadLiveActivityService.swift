#if os(iOS)
import ActivityKit
import Foundation
import UIKit

@available(iOS 16.1, *)
struct UploadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let progress: Double
        let currentFileName: String
        let completedCount: Int
        let totalCount: Int
        let pendingCount: Int
        let statusText: String
    }
}

@MainActor
final class UploadLiveActivityService {
    static let shared = UploadLiveActivityService()

    private var activity: Activity<UploadActivityAttributes>?

    /// Tracks the last time we sent an update so we can throttle high-frequency progress ticks.
    private var lastUpdateTime: Date = .distantPast
    /// Minimum seconds between Live Activity updates (ActivityKit rate-limits anyway, but this
    /// avoids flooding the queue and causing perceived lag from queued-up stale updates).
    private let updateInterval: TimeInterval = 0.25

    func sync(tasks: [FileUploadTask]) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Task { await end() }
            return
        }

        let relevantTasks = tasks.filter {
            $0.status == .pending || $0.status == .uploading || $0.status == .completed
        }

        let activeTasks = tasks.filter {
            $0.status == .pending || $0.status == .uploading
        }

        guard !relevantTasks.isEmpty, !activeTasks.isEmpty else {
            Task { await end() }
            return
        }

        // Throttle: skip update if we just sent one, unless status changed (not just progress).
        let now = Date()
        let elapsed = now.timeIntervalSince(lastUpdateTime)
        guard elapsed >= updateInterval else { return }
        lastUpdateTime = now

        let completedCount = relevantTasks.filter { $0.status == .completed }.count
        let aggregateProgress = relevantTasks.reduce(0.0) { partialResult, task in
            partialResult + (task.status == .completed ? 1.0 : task.progress)
        } / Double(relevantTasks.count)

        let currentTask = activeTasks.first(where: { $0.status == .uploading }) ?? activeTasks.first
        let pendingCount = tasks.filter { $0.status == .pending }.count
        let contentState = UploadActivityAttributes.ContentState(
            progress: aggregateProgress,
            currentFileName: currentTask?.fileName ?? "Preparing uploads",
            completedCount: completedCount,
            totalCount: relevantTasks.count,
            pendingCount: pendingCount,
            statusText: pendingCount == 0 ? "Finishing" : "Uploading"
        )

        // Upsert inline on MainActor — no extra Task hop needed.
        Task { await upsert(contentState: contentState) }
    }

    private func upsert(contentState: UploadActivityAttributes.ContentState) async {
        let content = ActivityContent(state: contentState, staleDate: nil)

        if let activity {
            await activity.update(content)
            return
        }

        guard UIApplication.shared.applicationState == .active else { return }

        do {
            activity = try Activity.request(
                attributes: UploadActivityAttributes(),
                content: content
            )
        } catch {
            activity = nil
        }
    }

    func end() async {
        guard let activity else { return }
        let finalState = UploadActivityAttributes.ContentState(
            progress: 1.0,
            currentFileName: "Done",
            completedCount: 0,
            totalCount: 0,
            pendingCount: 0,
            statusText: "Complete"
        )
        await activity.end(
            ActivityContent(state: finalState, staleDate: Date()),
            dismissalPolicy: .immediate
        )
        self.activity = nil
    }
}
#endif
