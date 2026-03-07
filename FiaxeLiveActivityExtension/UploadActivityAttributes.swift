#if os(iOS)
import ActivityKit
import Foundation

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
#endif
